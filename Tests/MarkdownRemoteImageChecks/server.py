import base64,http.server,json,threading,time,sys
png=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2Jx8AAAAASUVORK5CYII=')
counts={};active=0;maximum=0;lock=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  global active,maximum
  path=self.path.split('?')[0]
  if path=='/stats':
   with lock: body=json.dumps(dict(counts=counts,active=active,maximum=maximum)).encode()
   self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
  with lock:counts[self.path]=counts.get(self.path,0)+1;active+=1;maximum=max(maximum,active)
  try:
   if path.startswith('/slow'):time.sleep(.35)
   if path=='/hold':time.sleep(2)
   payload=(b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>' if path=='/svg' else b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' if path=='/svg-active' else png)
   self.send_response(404 if path=='/missing' else 200)
   self.send_header('Cache-Control','public, max-age=3600' if path=='/cacheable' else 'no-store')
   self.send_header('Content-Type','text/html' if path=='/html' else 'image/svg+xml' if path.startswith('/svg') else 'image/png')
   if path=='/header-large':self.send_header('Content-Length',str(9*1024*1024))
   elif path!='/stream-large':self.send_header('Content-Length',str(len(payload)))
   self.end_headers()
   if path=='/stream-large':
    for _ in range(144):self.wfile.write(b'x'*65536);self.wfile.flush()
   elif path!='/header-large':self.wfile.write(payload)
  except (BrokenPipeError,ConnectionResetError):pass
  finally:
   with lock:active-=1
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port));server.serve_forever()
