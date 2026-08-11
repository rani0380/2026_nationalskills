package main

import (
	"database/sql"
	"log"
	"nationalskills-practice-apps/internal/common"
	"net/http"
	"strings"
)

type userRequest struct {
	RequestID string `json:"requestid"`
	UUID      string `json:"uuid"`
	Username  string `json:"username"`
	Email     string `json:"email"`
}
type userResponse struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
}

func main() {
	db, err := common.OpenMySQL()
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthcheck", common.Health(db))
	mux.HandleFunc("/v1/user", handler(db))
	log.Fatal(common.Listen("user", mux))
}
func handler(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			var in userRequest
			if !common.DecodeJSON(w, r, &in) || !common.RequireIdentity(w, in.RequestID, in.UUID) {
				return
			}
			if strings.TrimSpace(in.Username) == "" || strings.TrimSpace(in.Email) == "" {
				common.JSON(w, 403, map[string]string{"error": "username and email are required"})
				return
			}
			ctx, cancel := common.Context()
			defer cancel()
			_, err := db.ExecContext(ctx, `INSERT INTO user(id,username,email) VALUES(?,?,?) ON DUPLICATE KEY UPDATE username=VALUES(username),email=VALUES(email)`, in.Username, in.Username, in.Email)
			if err != nil {
				log.Printf("database error: %v", err)
				common.JSON(w, 500, map[string]string{"error": "database error"})
				return
			}
			common.JSON(w, 201, userResponse{in.Username, in.Username, in.Email})
		case http.MethodGet:
			requestID, uuid, email := r.URL.Query().Get("requestid"), r.URL.Query().Get("uuid"), r.URL.Query().Get("email")
			if !common.RequireIdentity(w, requestID, uuid) || email == "" {
				if email == "" {
					common.JSON(w, 403, map[string]string{"error": "email is required"})
				}
				return
			}
			var out userResponse
			ctx, cancel := common.Context()
			defer cancel()
			err := db.QueryRowContext(ctx, `SELECT id,username,email FROM user WHERE email=? LIMIT 1`, email).Scan(&out.ID, &out.Username, &out.Email)
			if err == sql.ErrNoRows {
				common.JSON(w, 404, map[string]string{"error": "user not found"})
				return
			}
			if err != nil {
				log.Printf("database error: %v", err)
				common.JSON(w, 500, map[string]string{"error": "database error"})
				return
			}
			common.JSON(w, 200, out)
		default:
			common.JSON(w, 404, map[string]string{"error": "not found"})
		}
	}
}
