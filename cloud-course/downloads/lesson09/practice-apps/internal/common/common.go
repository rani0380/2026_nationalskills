package common

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

var requestIDPattern = regexp.MustCompile(`^[0-9]{12}$`)
var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

type StatusWriter struct {
	http.ResponseWriter
	Status int
	Bytes  int
}

func (w *StatusWriter) WriteHeader(code int) { w.Status = code; w.ResponseWriter.WriteHeader(code) }
func (w *StatusWriter) Write(b []byte) (int, error) {
	if w.Status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	n, e := w.ResponseWriter.Write(b)
	w.Bytes += n
	return n, e
}

func AccessLog(app string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &StatusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		if sw.Status == 0 {
			sw.Status = 200
		}
		log.Printf(`app=%s method=%s path=%s status=%d bytes=%d duration_ms=%d remote=%q requestid=%q uuid=%q`, app, r.Method, r.URL.Path, sw.Status, sw.Bytes, time.Since(start).Milliseconds(), r.RemoteAddr, RequestValue(r, "requestid"), RequestValue(r, "uuid"))
	})
}

func RequestValue(r *http.Request, key string) string {
	if v := r.URL.Query().Get(key); v != "" {
		return v
	}
	if err := r.ParseMultipartForm(12 << 20); err == nil {
		if v := r.FormValue(key); v != "" {
			return v
		}
	}
	return ""
}
func ValidIdentity(requestID, uuid string) bool {
	return requestIDPattern.MatchString(requestID) && uuidPattern.MatchString(uuid)
}
func RequireIdentity(w http.ResponseWriter, requestID, uuid string) bool {
	if !ValidIdentity(requestID, uuid) {
		JSON(w, 403, map[string]string{"error": "invalid requestid or uuid"})
		return false
	}
	return true
}
func JSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		JSON(w, 403, map[string]string{"error": "invalid request"})
		return false
	}
	return true
}
func RequiredEnv(keys ...string) (map[string]string, error) {
	m := map[string]string{}
	for _, k := range keys {
		v := os.Getenv(k)
		if v == "" {
			return nil, fmt.Errorf("required environment variable %s is missing", k)
		}
		m[k] = v
	}
	return m, nil
}
func OpenMySQL() (*sql.DB, error) {
	e, err := RequiredEnv("MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_HOST", "MYSQL_PORT", "MYSQL_DBNAME")
	if err != nil {
		return nil, err
	}
	if _, err = strconv.Atoi(e["MYSQL_PORT"]); err != nil {
		return nil, errors.New("MYSQL_PORT must be an integer")
	}
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4&timeout=5s&readTimeout=5s&writeTimeout=5s", e["MYSQL_USER"], e["MYSQL_PASSWORD"], e["MYSQL_HOST"], e["MYSQL_PORT"], e["MYSQL_DBNAME"])
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(5 * time.Minute)
	ctx, cancel := Context()
	defer cancel()
	if err = db.PingContext(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}
func Context() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}
func Health(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			JSON(w, 404, map[string]string{"error": "not found"})
			return
		}
		if db != nil {
			ctx, cancel := Context()
			defer cancel()
			if err := db.PingContext(ctx); err != nil {
				JSON(w, 503, map[string]string{"error": "database unavailable"})
				return
			}
		}
		JSON(w, 200, map[string]string{"status": "ok"})
	}
}
func Listen(app string, h http.Handler) error {
	addr := ":8080"
	log.Printf("app=%s listening=%s", app, addr)
	s := &http.Server{Addr: addr, Handler: AccessLog(app, h), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	return s.ListenAndServe()
}
