from flask import Flask, jsonify, request

app = Flask(__name__)

@app.get("/health")
def health():
    return jsonify(status="ok", component="inventory")

@app.get("/v1/inventory")
def inventory():
    return jsonify(product_id=request.args.get("id", "P-100"), available=True, via="vpc-lattice")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
