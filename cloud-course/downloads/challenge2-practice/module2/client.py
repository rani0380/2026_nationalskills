import os
import requests
from flask import Flask, jsonify, request

app = Flask(__name__)

@app.get("/health")
def health():
    return jsonify(status="ok", component="client")

@app.get("/v1/client/inventory")
def inventory():
    base = os.environ["INVENTORY_URL"].rstrip("/")
    response = requests.get(base + "/v1/inventory", params={"id": request.args.get("id", "P-100")}, timeout=5)
    return (response.content, response.status_code, {"Content-Type": "application/json"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
