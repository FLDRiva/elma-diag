FROM golang:1.23-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o diag-server .

FROM alpine:3.20

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /app/diag-server .
COPY --from=builder /app/static ./static

USER nobody

EXPOSE 8080

ENTRYPOINT ["./diag-server"]
