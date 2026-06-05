#=================================================
echo "\n4-1"
aws lambda list-functions --region ap-southeast-1 --query "Functions[?FunctionName=='wsc2026-worldschool-management'].FunctionName" --output text | grep wsc2026-worldschool-management
#=================================================

#=================================================
echo "\n4-2"
aws lambda list-layers --region ap-southeast-1 --query "Layers[?LayerName=='wsc2026-worldschool-env-layer'].LayerName" --output text | grep wsc2026-worldschool-env-layer
#=================================================

#=================================================
echo "\n4-3"
aws dynamodb list-tables --region ap-southeast-1 --query "TableNames[?@=='wsc2026-worldschool-table']" --output text | grep wsc2026-worldschool-table
#=================================================

#=================================================
echo "\n4-4"
aws dynamodb describe-table --region ap-southeast-1 --table-name wsc2026-worldschool-table --query "Table.AttributeDefinitions" --output text
aws dynamodb describe-table --region ap-southeast-1 --table-name wsc2026-worldschool-table --query "Table.DeletionProtectionEnabled"
#=================================================

#=================================================
echo "\n4-5"
aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].name" --output text | grep wsc2026-worldschool-api
aws apigateway get-resources --region ap-southeast-1 --rest-api-id $(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text) --query "items[0].resourceMethods"
#=================================================

#=================================================
echo "\n4-6"
aws dynamodb scan --table-name wsc2026-worldschool-table --attributes-to-get "admission_year" "student_name" --query "Items[*].{PK:admission_year.N, SK:student_name.S}" --output json | jq -c '.[]' | while read item; do itemPk=$(echo $item | jq -r '.PK'); itemSk=$(echo $item | jq -r '.SK'); aws dynamodb delete-item --table-name wsc2026-worldschool-table --key "{\"admission_year\":{\"N\":\"$itemPk\"}, \"student_name\":{\"S\":\"$itemSk\"}}"; done

curl -L -X POST -d '{"admission_year": 2026, "student_name":"홍길동"}' -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
curl -L -X GET -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage" | jq '.'
curl -L -G -d "admission_year=2026" --data-urlencode "student_name=홍길동" -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
curl -L -G -d "admission_year=2026" -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
curl -L -X POST -d '{"admission_year": 2026}' -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
curl -L -X POST -d '{"admission_year": "2026", "student_name": "홍길동"}' -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
curl -L -G -d "admission_year=2026" --data-urlencode "student_name=xyz" -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
curl -L -X DELETE -w "\n%{http_code}\n" "https://$(aws apigateway get-rest-apis --region ap-southeast-1 --query "items[?name=='wsc2026-worldschool-api'].id" --output text).execute-api.ap-southeast-1.amazonaws.com/wsc2026-worldschool-api-stage"
#=================================================