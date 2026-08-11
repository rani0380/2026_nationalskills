package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"nationalskills-practice-apps/internal/common"
	"net/http"
)

type request struct {
	RequestID string `json:"requestid"`
	UUID      string `json:"uuid"`
	Length    int    `json:"length"`
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthcheck", common.Health(nil))
	mux.HandleFunc("/v1/stress", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			common.JSON(w, 404, map[string]string{"error": "not found"})
			return
		}
		var in request
		if !common.DecodeJSON(w, r, &in) || !common.RequireIdentity(w, in.RequestID, in.UUID) {
			return
		}
		if in.Length < 1 || in.Length > 100000 {
			common.JSON(w, 403, map[string]string{"error": "length must be between 1 and 100000"})
			return
		}
		data := []byte(in.RequestID + in.UUID)
		sum := sha256.Sum256(data)
		for i := 0; i < in.Length*256; i++ {
			sum = sha256.Sum256(sum[:])
		}
		common.JSON(w, 201, map[string]any{"length": in.Length, "checksum": hex.EncodeToString(sum[:])})
	})
	log.Fatal(common.Listen("stress", mux))
}
