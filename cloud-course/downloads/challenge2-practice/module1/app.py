import os
from flask import Flask, jsonify, request
import boto3

app = Flask(__name__)
region = os.getenv("AWS_REGION", "ap-northeast-2")
ddb = boto3.resource("dynamodb", region_name=region)
orders = ddb.Table("practice-orders")
products = ddb.Table("practice-products")

@app.get("/health")
def health():
    return jsonify(status="ok", database="dynamodb", region=region)

@app.get("/v1/orders/<order_id>")
def order(order_id):
    item = orders.get_item(Key={"orderId": order_id}).get("Item")
    return (jsonify(item), 200) if item else (jsonify(error="not found"), 404)

@app.get("/v1/customers/<customer_id>/orders")
def customer_orders(customer_id):
    result = orders.query(IndexName="CustomerCreatedAtIndex", KeyConditionExpression="customerId = :c", ExpressionAttributeValues={":c": customer_id}, ScanIndexForward=False)
    return jsonify(items=result.get("Items", []))

@app.get("/v1/products/low-stock")
def low_stock():
    warehouse = request.args.get("warehouseId", "WH-A")
    result = products.query(IndexName="WarehouseStockIndex", KeyConditionExpression="warehouseId = :w", ExpressionAttributeValues={":w": warehouse})
    return jsonify(items=result.get("Items", []))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
