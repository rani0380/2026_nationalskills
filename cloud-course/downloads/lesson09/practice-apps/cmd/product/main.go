package main

import (
	"context"
	"database/sql"
	"fmt"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"log"
	"mime/multipart"
	"nationalskills-practice-apps/internal/common"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type productRequest struct {
	RequestID string  `json:"requestid"`
	UUID      string  `json:"uuid"`
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Price     float64 `json:"price"`
}
type productResponse struct {
	ID        string         `json:"id"`
	Name      string         `json:"name"`
	Price     float64        `json:"price"`
	ImagePath sql.NullString `json:"-"`
}
type s3API interface {
	PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error)
}

func main() {
	db, err := common.OpenMySQL()
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthcheck", common.Health(db))
	mux.HandleFunc("/v1/product", handler(db, s3.NewFromConfig(cfg), os.Getenv("S3_BUCKET")))
	log.Fatal(common.Listen("product", mux))
}
func handler(db *sql.DB, s3c s3API, bucket string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			var in productRequest
			if !common.DecodeJSON(w, r, &in) || !common.RequireIdentity(w, in.RequestID, in.UUID) {
				return
			}
			if strings.TrimSpace(in.ID) == "" || strings.TrimSpace(in.Name) == "" {
				common.JSON(w, 403, map[string]string{"error": "id and name are required"})
				return
			}
			ctx, cancel := common.Context()
			defer cancel()
			_, err := db.ExecContext(ctx, `INSERT INTO product(id,name,price) VALUES(?,?,?) ON DUPLICATE KEY UPDATE name=VALUES(name),price=VALUES(price)`, in.ID, in.Name, in.Price)
			if err != nil {
				log.Printf("database error: %v", err)
				common.JSON(w, 500, map[string]string{"error": "database error"})
				return
			}
			common.JSON(w, 201, map[string]any{"id": in.ID, "name": in.Name, "price": in.Price})
		case http.MethodGet:
			id := r.URL.Query().Get("id")
			if !common.RequireIdentity(w, r.URL.Query().Get("requestid"), r.URL.Query().Get("uuid")) || id == "" {
				if id == "" {
					common.JSON(w, 403, map[string]string{"error": "id is required"})
				}
				return
			}
			var out productResponse
			ctx, cancel := common.Context()
			defer cancel()
			err := db.QueryRowContext(ctx, `SELECT id,name,price,image_path FROM product WHERE id=?`, id).Scan(&out.ID, &out.Name, &out.Price, &out.ImagePath)
			if err == sql.ErrNoRows {
				common.JSON(w, 404, map[string]string{"error": "product not found"})
				return
			}
			if err != nil {
				common.JSON(w, 500, map[string]string{"error": "database error"})
				return
			}
			resp := map[string]any{"id": out.ID, "name": out.Name, "price": out.Price}
			if out.ImagePath.Valid {
				resp["image_path"] = out.ImagePath.String
			}
			common.JSON(w, 200, resp)
		case http.MethodPut:
			putImage(w, r, db, s3c, bucket)
		default:
			common.JSON(w, 404, map[string]string{"error": "not found"})
		}
	}
}
func putImage(w http.ResponseWriter, r *http.Request, db *sql.DB, s3c s3API, bucket string) {
	if bucket == "" {
		common.JSON(w, 500, map[string]string{"error": "S3_BUCKET is missing"})
		return
	}
	if err := r.ParseMultipartForm(12 << 20); err != nil {
		common.JSON(w, 403, map[string]string{"error": "invalid multipart request"})
		return
	}
	if !common.RequireIdentity(w, r.FormValue("requestid"), r.FormValue("uuid")) {
		return
	}
	id := r.FormValue("id")
	file, header, err := r.FormFile("image")
	if err != nil || id == "" {
		common.JSON(w, 403, map[string]string{"error": "id and image are required"})
		return
	}
	defer file.Close()
	key := id + safeExt(header)
	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	ctx, cancel := common.Context()
	defer cancel()
	_, err = s3c.PutObject(ctx, &s3.PutObjectInput{Bucket: &bucket, Key: &key, Body: file, ContentType: &contentType})
	if err != nil {
		log.Printf("s3 error: %v", err)
		common.JSON(w, 500, map[string]string{"error": "image upload failed"})
		return
	}
	_, err = db.ExecContext(ctx, `UPDATE product SET image_path=? WHERE id=?`, "/"+key, id)
	if err != nil {
		common.JSON(w, 500, map[string]string{"error": "database error"})
		return
	}
	common.JSON(w, 200, map[string]string{"id": id, "image_path": "/" + key})
}
func safeExt(h *multipart.FileHeader) string {
	e := strings.ToLower(filepath.Ext(h.Filename))
	switch e {
	case ".jpg", ".jpeg", ".png", ".gif", ".webp":
		return e
	default:
		return ".bin"
	}
}

var _ = fmt.Sprintf
