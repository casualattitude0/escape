// Command relay-server is the lobby directory + packet relay for Escape's
// internet-wide "Browse Games" flow. A host opens one WebSocket connection
// here and registers a room; joining clients each open their own connection
// and are wired into that room. Neither side needs a reachable inbound
// address — every packet between host and clients passes through this
// process. Room state is kept entirely in memory; run a single instance
// (see deploy.sh, --min-instances=1 --max-instances=1).
package main

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	frameControl byte = 0x00
	frameData    byte = 0x01

	hostPeerID = uint32(1)

	pingInterval = 20 * time.Second
	pongWait     = 60 * time.Second
)

// controlMsg is the JSON payload of a frameControl message. Only the fields
// relevant to a given "op" are set.
type controlMsg struct {
	Op         string `json:"op"`
	Name       string `json:"name,omitempty"`
	MaxPlayers int    `json:"max_players,omitempty"`
	RoomID     string `json:"room_id,omitempty"`
	PeerID     uint32 `json:"peer_id,omitempty"`
	Reason     string `json:"reason,omitempty"`
	// Payload is the opaque body of an "rtc" message (WebRTC signaling: SDP
	// offers/answers, ICE candidates, path-switch markers). The relay never
	// parses it — it only routes: host->relay carries PeerID naming the target
	// client; relay->host stamps PeerID with the sending client.
	Payload json.RawMessage `json:"payload,omitempty"`
}

// conn wraps a websocket.Conn with a write mutex — gorilla/websocket forbids
// concurrent writers on the same connection, and a client's socket can be
// written to both by the host's forwarding goroutine and by room-lifecycle
// events (e.g. a "host_left" notice) at the same time.
type conn struct {
	ws      *websocket.Conn
	writeMu sync.Mutex
}

func (c *conn) writeRaw(b []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return c.ws.WriteMessage(websocket.BinaryMessage, b)
}

func (c *conn) sendControl(msg controlMsg) error {
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return c.writeRaw(append([]byte{frameControl}, b...))
}

// sendData forwards a data frame verbatim, without the relay's own framing
// prefix — used for relay -> client (a client only ever hears from the host,
// so no sender tag is needed) and relay -> host with the sender tag already
// applied by the caller.
func (c *conn) sendData(payload []byte) error {
	buf := make([]byte, 1+len(payload))
	buf[0] = frameData
	copy(buf[1:], payload)
	return c.writeRaw(buf)
}

func (c *conn) sendDataFrom(peerID uint32, payload []byte) error {
	buf := make([]byte, 1+4+len(payload))
	buf[0] = frameData
	binary.LittleEndian.PutUint32(buf[1:5], peerID)
	copy(buf[5:], payload)
	return c.writeRaw(buf)
}

// room is one open game. host is nil only during the brief window between
// accept and the "host" control message; once set it never changes.
type room struct {
	id         string
	name       string
	maxPlayers int
	createdAt  time.Time

	mu         sync.Mutex
	host       *conn
	clients    map[uint32]*conn
	nextPeerID uint32
}

func newRoom(id, name string, maxPlayers int) *room {
	return &room{
		id:         id,
		name:       name,
		maxPlayers: maxPlayers,
		createdAt:  time.Now(),
		clients:    map[uint32]*conn{},
		nextPeerID: hostPeerID + 1,
	}
}

func (r *room) playerCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.clients)
}

// addClient assigns a peer id and registers the connection, or refuses if the
// room is full. Notifies the host of the new peer.
func (r *room) addClient(c *conn) (uint32, error) {
	r.mu.Lock()
	if len(r.clients) >= r.maxPlayers {
		r.mu.Unlock()
		return 0, errRoomFull
	}
	id := r.nextPeerID
	r.nextPeerID++
	r.clients[id] = c
	host := r.host
	r.mu.Unlock()

	if host != nil {
		host.sendControl(controlMsg{Op: "peer_joined", PeerID: id})
	}
	return id, nil
}

func (r *room) removeClient(id uint32) {
	r.mu.Lock()
	_, ok := r.clients[id]
	delete(r.clients, id)
	host := r.host
	r.mu.Unlock()
	if ok && host != nil {
		host.sendControl(controlMsg{Op: "peer_left", PeerID: id})
	}
}

// forwardFromHost routes a data frame the host sent: target 0 means
// broadcast to every client, otherwise it's unicast to one peer id.
func (r *room) forwardFromHost(target uint32, payload []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if target == 0 {
		for _, c := range r.clients {
			c.sendData(payload)
		}
		return
	}
	if c, ok := r.clients[target]; ok {
		c.sendData(payload)
	}
}

// forwardRTCToClient relays a host-sent "rtc" control message to one client,
// with the routing PeerID stripped (a client only ever signals with the host).
func (r *room) forwardRTCToClient(target uint32, payload json.RawMessage) {
	r.mu.Lock()
	c, ok := r.clients[target]
	r.mu.Unlock()
	if ok {
		c.sendControl(controlMsg{Op: "rtc", Payload: payload})
	}
}

// forwardRTCToHost relays a client-sent "rtc" control message to the host,
// stamped with the sender's peer id.
func (r *room) forwardRTCToHost(from uint32, payload json.RawMessage) {
	r.mu.Lock()
	host := r.host
	r.mu.Unlock()
	if host != nil {
		host.sendControl(controlMsg{Op: "rtc", PeerID: from, Payload: payload})
	}
}

func (r *room) forwardToHost(from uint32, payload []byte) {
	r.mu.Lock()
	host := r.host
	r.mu.Unlock()
	if host != nil {
		host.sendDataFrom(from, payload)
	}
}

// close notifies every client the host is gone and drops the room from the
// directory. Called once, when the host's connection loop exits.
func (r *room) close() {
	roomsMu.Lock()
	delete(rooms, r.id)
	roomsMu.Unlock()

	r.mu.Lock()
	clients := make([]*conn, 0, len(r.clients))
	for _, c := range r.clients {
		clients = append(clients, c)
	}
	r.mu.Unlock()

	for _, c := range clients {
		c.sendControl(controlMsg{Op: "host_left"})
		c.ws.Close()
	}
}

var (
	errRoomFull   = &relayError{"room_full"}
	errNotFound   = &relayError{"not_found"}
	errBadRequest = &relayError{"bad_request"}
)

type relayError struct{ reason string }

func (e *relayError) Error() string { return e.reason }

var (
	roomsMu sync.Mutex
	rooms   = map[string]*room{}
)

func newRoomID() string {
	b := make([]byte, 4)
	rand.Read(b)
	return hex.EncodeToString(b)
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true }, // no browser session/cookies at stake
}

type roomInfo struct {
	RoomID      string `json:"room_id"`
	Name        string `json:"name"`
	PlayerCount int    `json:"player_count"`
	MaxPlayers  int    `json:"max_players"`
}

func handleRooms(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "application/json")

	roomsMu.Lock()
	snapshot := make([]*room, 0, len(rooms))
	for _, rm := range rooms {
		snapshot = append(snapshot, rm)
	}
	roomsMu.Unlock()

	list := make([]roomInfo, 0, len(snapshot))
	for _, rm := range snapshot {
		list = append(list, roomInfo{
			RoomID:      rm.id,
			Name:        rm.name,
			PlayerCount: rm.playerCount(),
			MaxPlayers:  rm.maxPlayers,
		})
	}
	json.NewEncoder(w).Encode(list)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// handleConnect accepts the raw WebSocket, waits for the client's opening
// control message (must be "host" or "join"), and then hands off to the
// matching read loop for the connection's lifetime.
func handleConnect(w http.ResponseWriter, r *http.Request) {
	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade failed: %v", err)
		return
	}
	c := &conn{ws: ws}
	ws.SetReadDeadline(time.Now().Add(pongWait))
	ws.SetPongHandler(func(string) error {
		ws.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	go keepAlive(c)

	frameType, payload, err := readFrame(ws)
	if err != nil {
		log.Printf("initial frame read failed: %v", err)
		ws.Close()
		return
	}
	if frameType != frameControl {
		c.sendControl(controlMsg{Op: "join_failed", Reason: errBadRequest.Error()})
		ws.Close()
		return
	}
	var msg controlMsg
	if err := json.Unmarshal(payload, &msg); err != nil {
		ws.Close()
		return
	}

	switch msg.Op {
	case "host":
		runHost(c, msg)
	case "join":
		runClient(c, msg)
	default:
		ws.Close()
	}
}

func keepAlive(c *conn) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for range ticker.C {
		c.writeMu.Lock()
		err := c.ws.WriteMessage(websocket.PingMessage, nil)
		c.writeMu.Unlock()
		if err != nil {
			return
		}
	}
}

func readFrame(ws *websocket.Conn) (byte, []byte, error) {
	_, data, err := ws.ReadMessage()
	if err != nil {
		return 0, nil, err
	}
	if len(data) == 0 {
		return 0, nil, errBadRequest
	}
	return data[0], data[1:], nil
}

func runHost(c *conn, msg controlMsg) {
	maxPlayers := msg.MaxPlayers
	if maxPlayers <= 0 || maxPlayers > 16 {
		maxPlayers = 4
	}
	name := msg.Name
	if name == "" {
		name = "Untitled Room"
	}

	roomsMu.Lock()
	id := newRoomID()
	for rooms[id] != nil { // astronomically unlikely, but keep it correct
		id = newRoomID()
	}
	rm := newRoom(id, name, maxPlayers)
	rm.host = c
	rooms[id] = rm
	roomsMu.Unlock()

	if err := c.sendControl(controlMsg{Op: "hosted", RoomID: id}); err != nil {
		rm.close()
		return
	}
	log.Printf("room %s hosted: %q (max %d)", id, name, maxPlayers)

	defer rm.close()
	for {
		frameType, payload, err := readFrame(c.ws)
		if err != nil {
			return
		}
		if frameType == frameControl {
			// Post-handshake control from the host: only "rtc" signaling is
			// routed; anything else (pings, unknown future ops) is ignored, so
			// old and new builds interoperate without a protocol version.
			var m controlMsg
			if json.Unmarshal(payload, &m) == nil && m.Op == "rtc" && m.PeerID != 0 {
				rm.forwardRTCToClient(m.PeerID, m.Payload)
			}
			continue
		}
		if frameType != frameData || len(payload) < 4 {
			continue
		}
		target := binary.LittleEndian.Uint32(payload[:4])
		rm.forwardFromHost(target, payload[4:])
	}
}

func runClient(c *conn, msg controlMsg) {
	roomsMu.Lock()
	rm := rooms[msg.RoomID]
	roomsMu.Unlock()
	if rm == nil {
		c.sendControl(controlMsg{Op: "join_failed", Reason: errNotFound.Error()})
		c.ws.Close()
		return
	}

	peerID, err := rm.addClient(c)
	if err != nil {
		c.sendControl(controlMsg{Op: "join_failed", Reason: err.Error()})
		c.ws.Close()
		return
	}
	if err := c.sendControl(controlMsg{Op: "joined", PeerID: peerID}); err != nil {
		rm.removeClient(peerID)
		return
	}
	log.Printf("room %s: peer %d joined", rm.id, peerID)

	defer rm.removeClient(peerID)
	for {
		frameType, payload, err := readFrame(c.ws)
		if err != nil {
			return
		}
		if frameType == frameControl {
			var m controlMsg
			if json.Unmarshal(payload, &m) == nil && m.Op == "rtc" {
				rm.forwardRTCToHost(peerID, m.Payload)
			}
			continue
		}
		if frameType != frameData {
			continue
		}
		rm.forwardToHost(peerID, payload)
	}
}

func main() {
	http.HandleFunc("/rooms", handleRooms)
	http.HandleFunc("/connect", handleConnect)
	http.HandleFunc("/", handleHealth)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	addr := ":" + port
	log.Printf("relay listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
