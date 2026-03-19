function handler(event) {
    var request = event.request;
    var host = request.headers.host && request.headers.host.value;
    var query = '';

    if (request.querystring) {
        var parts = [];
        for (var key in request.querystring) {
            if (Object.prototype.hasOwnProperty.call(request.querystring, key)) {
                parts.push(key + '=' + request.querystring[key].value);
            }
        }
        if (parts.length > 0) {
            query = '?' + parts.join('&');
        }
    }

    if (host === 'www.advantix.tech') {
        return {
            statusCode: 301,
            statusDescription: 'Moved Permanently',
            headers: {
                location: { value: 'https://advantix.tech' + request.uri + query }
            }
        };
    }

    if (request.uri === '/') {
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                location: { value: '/advantix/' }
            }
        };
    }

    return request;
}
