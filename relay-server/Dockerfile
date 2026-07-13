FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /relay-server .

FROM gcr.io/distroless/static-debian12
COPY --from=build /relay-server /relay-server
EXPOSE 8080
ENTRYPOINT ["/relay-server"]
