package main

import (
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func startTestServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/rooms", handleRooms)
	mux.HandleFunc("/connect", handleConnect)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/connect"
	return srv, wsURL
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { ws.Close() })
	return ws
}

func sendCtrl(t *testing.T, ws *websocket.Conn, msg controlMsg) {
	t.Helper()
	b, _ := json.Marshal(msg)
	if err := ws.WriteMessage(websocket.BinaryMessage, append([]byte{frameControl}, b...)); err != nil {
		t.Fatalf("send control: %v", err)
	}
}

func sendData(t *testing.T, ws *websocket.Conn, target uint32, payload []byte) {
	t.Helper()
	buf := make([]byte, 1+4+len(payload))
	buf[0] = frameData
	binary.LittleEndian.PutUint32(buf[1:5], target)
	copy(buf[5:], payload)
	if err := ws.WriteMessage(websocket.BinaryMessage, buf); err != nil {
		t.Fatalf("send data: %v", err)
	}
}

func sendClientData(t *testing.T, ws *websocket.Conn, payload []byte) {
	t.Helper()
	buf := append([]byte{frameData}, payload...)
	if err := ws.WriteMessage(websocket.BinaryMessage, buf); err != nil {
		t.Fatalf("send client data: %v", err)
	}
}

func readCtrl(t *testing.T, ws *websocket.Conn) controlMsg {
	t.Helper()
	ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, data, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if data[0] != frameControl {
		t.Fatalf("expected control frame, got type %d", data[0])
	}
	var msg controlMsg
	if err := json.Unmarshal(data[1:], &msg); err != nil {
		t.Fatalf("unmarshal control: %v", err)
	}
	return msg
}

// readData returns (senderOrEmpty, payload). Host-bound frames are tagged
// with a 4-byte sender id; client-bound frames are not.
func readDataTagged(t *testing.T, ws *websocket.Conn) (uint32, []byte) {
	t.Helper()
	ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, data, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if data[0] != frameData {
		t.Fatalf("expected data frame, got type %d", data[0])
	}
	return binary.LittleEndian.Uint32(data[1:5]), data[5:]
}

func readDataPlain(t *testing.T, ws *websocket.Conn) []byte {
	t.Helper()
	ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, data, err := ws.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if data[0] != frameData {
		t.Fatalf("expected data frame, got type %d", data[0])
	}
	return data[1:]
}

func TestHostJoinAndBidirectionalData(t *testing.T) {
	_, wsURL := startTestServer(t)

	host := dial(t, wsURL)
	sendCtrl(t, host, controlMsg{Op: "host", Name: "Test Room", MaxPlayers: 4})
	hosted := readCtrl(t, host)
	if hosted.Op != "hosted" || hosted.RoomID == "" {
		t.Fatalf("unexpected hosted reply: %+v", hosted)
	}

	client := dial(t, wsURL)
	sendCtrl(t, client, controlMsg{Op: "join", RoomID: hosted.RoomID})
	joined := readCtrl(t, client)
	if joined.Op != "joined" || joined.PeerID != 2 {
		t.Fatalf("unexpected joined reply: %+v", joined)
	}

	peerJoined := readCtrl(t, host)
	if peerJoined.Op != "peer_joined" || peerJoined.PeerID != 2 {
		t.Fatalf("host did not get peer_joined: %+v", peerJoined)
	}

	// host -> client (broadcast, target 0)
	sendData(t, host, 0, []byte("hello-client"))
	got := readDataPlain(t, client)
	if string(got) != "hello-client" {
		t.Fatalf("client got %q", got)
	}

	// client -> host (implicit target, tagged with sender)
	sendClientData(t, client, []byte("hello-host"))
	from, payload := readDataTagged(t, host)
	if from != 2 || string(payload) != "hello-host" {
		t.Fatalf("host got from=%d payload=%q", from, payload)
	}

	// client leaves -> host notified
	client.Close()
	peerLeft := readCtrl(t, host)
	if peerLeft.Op != "peer_left" || peerLeft.PeerID != 2 {
		t.Fatalf("host did not get peer_left: %+v", peerLeft)
	}
}

// The relay must route "rtc" control messages (WebRTC signaling envelopes)
// both ways — target-addressed host->client, sender-stamped client->host —
// without parsing the payload, and without disturbing the data path. Unknown
// post-handshake control ops must stay ignored (old/new build interop).
func TestRTCSignalingRouting(t *testing.T) {
	_, wsURL := startTestServer(t)

	host := dial(t, wsURL)
	sendCtrl(t, host, controlMsg{Op: "host", Name: "RTC Room", MaxPlayers: 4})
	hosted := readCtrl(t, host)
	if hosted.Op != "hosted" {
		t.Fatalf("unexpected hosted reply: %+v", hosted)
	}

	client := dial(t, wsURL)
	sendCtrl(t, client, controlMsg{Op: "join", RoomID: hosted.RoomID})
	if joined := readCtrl(t, client); joined.Op != "joined" || joined.PeerID != 2 {
		t.Fatalf("unexpected joined reply: %+v", joined)
	}
	if pj := readCtrl(t, host); pj.Op != "peer_joined" {
		t.Fatalf("host did not get peer_joined: %+v", pj)
	}

	// host -> client: routed by PeerID, payload untouched, no PeerID leaked.
	offer := json.RawMessage(`{"kind":"offer","sdp":"v=0 fake"}`)
	sendCtrl(t, host, controlMsg{Op: "rtc", PeerID: 2, Payload: offer})
	got := readCtrl(t, client)
	if got.Op != "rtc" || got.PeerID != 0 || string(got.Payload) != string(offer) {
		t.Fatalf("client got %+v payload=%s", got, got.Payload)
	}

	// client -> host: stamped with the sender's peer id.
	answer := json.RawMessage(`{"kind":"answer","sdp":"v=0 fake"}`)
	sendCtrl(t, client, controlMsg{Op: "rtc", Payload: answer})
	got = readCtrl(t, host)
	if got.Op != "rtc" || got.PeerID != 2 || string(got.Payload) != string(answer) {
		t.Fatalf("host got %+v payload=%s", got, got.Payload)
	}

	// Unknown control ops (both directions) are ignored, and an rtc to a
	// nonexistent peer is dropped — none of it may stall the data path.
	sendCtrl(t, host, controlMsg{Op: "future_op"})
	sendCtrl(t, client, controlMsg{Op: "ping"})
	sendCtrl(t, host, controlMsg{Op: "rtc", PeerID: 99, Payload: offer})
	sendData(t, host, 2, []byte("still-works"))
	if payload := readDataPlain(t, client); string(payload) != "still-works" {
		t.Fatalf("data path broken after control noise: %q", payload)
	}
	sendClientData(t, client, []byte("uphill"))
	if from, payload := readDataTagged(t, host); from != 2 || string(payload) != "uphill" {
		t.Fatalf("host got from=%d payload=%q", from, payload)
	}
}

func TestJoinUnknownRoom(t *testing.T) {
	_, wsURL := startTestServer(t)
	client := dial(t, wsURL)
	sendCtrl(t, client, controlMsg{Op: "join", RoomID: "does-not-exist"})
	reply := readCtrl(t, client)
	if reply.Op != "join_failed" || reply.Reason != "not_found" {
		t.Fatalf("unexpected reply: %+v", reply)
	}
}

func TestRoomListedAndRemovedOnHostDisconnect(t *testing.T) {
	srv, wsURL := startTestServer(t)

	host := dial(t, wsURL)
	sendCtrl(t, host, controlMsg{Op: "host", Name: "Listed Room", MaxPlayers: 2})
	hosted := readCtrl(t, host)

	resp, err := http.Get(srv.URL + "/rooms")
	if err != nil {
		t.Fatalf("GET /rooms: %v", err)
	}
	var list []roomInfo
	json.NewDecoder(resp.Body).Decode(&list)
	resp.Body.Close()
	found := false
	for _, r := range list {
		if r.RoomID == hosted.RoomID && r.Name == "Listed Room" {
			found = true
		}
	}
	if !found {
		t.Fatalf("room not listed: %+v", list)
	}

	client := dial(t, wsURL)
	sendCtrl(t, client, controlMsg{Op: "join", RoomID: hosted.RoomID})
	readCtrl(t, client) // joined

	host.Close()
	hostLeft := readCtrl(t, client)
	if hostLeft.Op != "host_left" {
		t.Fatalf("client did not get host_left: %+v", hostLeft)
	}

	time.Sleep(100 * time.Millisecond) // let the server-side close finish
	resp2, _ := http.Get(srv.URL + "/rooms")
	var list2 []roomInfo
	json.NewDecoder(resp2.Body).Decode(&list2)
	resp2.Body.Close()
	for _, r := range list2 {
		if r.RoomID == hosted.RoomID {
			t.Fatalf("room still listed after host left: %+v", r)
		}
	}
}

func TestRoomFull(t *testing.T) {
	_, wsURL := startTestServer(t)
	host := dial(t, wsURL)
	sendCtrl(t, host, controlMsg{Op: "host", Name: "Tiny", MaxPlayers: 1})
	hosted := readCtrl(t, host)

	c1 := dial(t, wsURL)
	sendCtrl(t, c1, controlMsg{Op: "join", RoomID: hosted.RoomID})
	j1 := readCtrl(t, c1)
	if j1.Op != "joined" {
		t.Fatalf("first client should join: %+v", j1)
	}
	readCtrl(t, host) // peer_joined

	c2 := dial(t, wsURL)
	sendCtrl(t, c2, controlMsg{Op: "join", RoomID: hosted.RoomID})
	j2 := readCtrl(t, c2)
	if j2.Op != "join_failed" || j2.Reason != "room_full" {
		t.Fatalf("second client should be refused: %+v", j2)
	}
}
