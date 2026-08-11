function handler(event) {
  var request = event.request;
  if (request.uri.startsWith('/images/')) {
    request.uri = request.uri.substring('/images'.length);
  }
  return request;
}