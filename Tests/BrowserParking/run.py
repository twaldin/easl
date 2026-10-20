#!/usr/bin/env python3
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import json
from pathlib import Path
import threading
import time
import traceback
import uuid


def main():
    parser = argparse.ArgumentParser(description='Verify browser JavaScript state survives a native pan outside the parking margin and back before 120 seconds.')
    parser.add_argument('--checkout', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--window-helper', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('scale', args.checkout / 'scripts/perf-scale.py')
    scale = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scale)
    scale.require_guest()
    args.out.mkdir(parents=True)
    options = argparse.Namespace(fixtures=args.out / 'fixtures', ssh=None, easld=None, window_helper=args.window_helper)
    run = scale.Run(options, args.app, 50, 'local', args.out)
    result = {'ok': False, 'http_events': []}
    event_lock = threading.Lock()
    nonce = uuid.uuid4().hex.upper()
    initial_token = 'BROWSERSTATEALPHA'
    returned_token = 'BROWSERSTATEBETA'
    initial_title = 'Retained browser'
    returned_title = 'Returned browser'
    fixture = b'''<!doctype html><html><head><meta charset="utf-8"><title>Fresh browser</title>
<style>html,body{margin:0;background:#c4efdc;color:#102a20}main{padding:30px;font:bold 42px monospace}</style>
</head><body><main id="state">FRESHLOAD</main><script>
window.browserParkingBoot = String(Date.now()) + ':' + String(Math.random());
</script></body></html>'''
    (args.out / 'fixture.html').write_bytes(fixture)

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(2)
            super().setup()

        def log_message(self, *_arguments):
            pass

        def do_GET(self):
            with event_lock:
                result['http_events'].append({'path': self.path, 'time': time.monotonic()})
            if self.path != '/state':
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(fixture)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            try:
                self.wfile.write(fixture)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = HTTPServer(('127.0.0.1', 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, name='BrowserParkingHTTP')
    url = 'http://127.0.0.1:' + str(server.server_port) + '/state'
    result['url'] = url
    server_started = False
    browser = None
    away_started = None
    state_script = '''(() => ({nonce: window.browserParkingState ?? null,
        boot: window.browserParkingBoot ?? null, title: document.title,
        body: document.querySelector('#state')?.textContent ?? null, url: location.href}))()'''

    def page(method, params=None):
        return scale.rpc(run.home / 'cmux.sock', method, dict(params or {}, surface_id=browser['id']), timeout=15)

    def state():
        return page('browser.eval', {'script': state_script})['value']

    def pan_to(target):
        for _ in range(6):
            view = run.call('view.get')['viewport']
            assert view['zoom'] == target['zoom'] == 1, 'Native board pan must preserve actual-size zoom'
            dx = target['rect']['x'] - view['rect']['x']
            dy = target['rect']['y'] - view['rect']['y']
            if abs(dx) <= 1 and abs(dy) <= 1:
                return view
            run.dev('input', 'drag', 20, 220, 20 - dx, 220 - dy, '--middle')
            time.sleep(.2)
        view = run.call('view.get')['viewport']
        assert all(abs(view['rect'][key] - target['rect'][key]) <= 3 for key in ('x', 'y')), {'message': 'Native pan did not reach its target', 'current': view, 'target': target}
        return view

    def capture(name):
        windows = json.loads(scale.command(args.window_helper, run.pid))
        window = max(windows, key=lambda value: value['kCGWindowBounds']['Width'] * value['kCGWindowBounds']['Height'])
        image = args.out / (name + '.png')
        receipt = scale.native.capture(run.home, window['kCGWindowNumber'], image, accessibility=True)
        text = scale.frame_text(args.window_helper, image)
        return {'image': str(image), 'window': window['kCGWindowNumber'], 'capture_id': receipt['capture_id'],
                'elements': receipt['elements'], 'lines': text['lines'], 'viewport': run.call('view.get')['viewport']}

    def native_page(name, token, title):
        deadline = time.monotonic() + 15
        attempt = 0
        while True:
            snapshot = capture(name + '-' + str(attempt))
            pixels = ''.join(''.join(snapshot['lines']).upper().split())
            close = [element for element in snapshot['elements']
                     if element.get('role') == 'AXButton' and element.get('label') == 'Close ' + title]
            if token in pixels and ''.join(title.upper().split()) in pixels and len(close) == 1:
                return snapshot
            assert time.monotonic() < deadline, {'message': 'Native browser body and title did not appear', 'token': token, 'title': title, 'snapshot': snapshot}
            attempt += 1
            time.sleep(.1)

    def document_requests():
        with event_lock:
            return sum(event['path'] == '/state' for event in result['http_events'])

    try:
        server_thread.start()
        server_started = True
        run.start()
        result['pid'] = run.pid
        result['home'] = str(run.home)
        run.dev('input', 'mainmenu', 'View/Actual Size')
        time.sleep(.5)
        before = run.call('view.get')['viewport']
        rect = before['rect']
        frame = {'x': rect['x'] + 50, 'y': rect['y'] + 60, 'w': 700, 'h': 280}
        assert rect['w'] >= 750 and rect['h'] >= 340, 'The owned native viewport must fit the browser body and title'
        browser = run.call('object.create', {'type': 'browser', 'props': {'url': url}, 'frame': frame})['object']
        result['browser'] = browser
        page('browser.wait', {'load_state': 'complete', 'timeout_ms': 10000})
        fresh = result['fresh'] = state()
        assert fresh['url'] == url and fresh['body'] == 'FRESHLOAD' and fresh['nonce'] is None and fresh['boot'], fresh
        assert document_requests() == 1, 'The fixture must begin with exactly one real page load'
        page('browser.eval', {'script': '(() => { window.browserParkingState = ' + json.dumps(nonce) + '; document.title = ' + json.dumps(initial_title) + '; document.querySelector("#state").textContent = ' + json.dumps(initial_token) + '; return true; })()'})
        expected = {'nonce': nonce, 'boot': fresh['boot'], 'title': initial_title, 'body': initial_token, 'url': url}
        result['before_state'] = state()
        assert result['before_state'] == expected, 'The live page must hold the unique heap-only JavaScript state'
        result['before_native'] = native_page('001-before', initial_token, initial_title)
        before = result['before_native']['viewport']
        away = {'zoom': 1, 'rect': dict(before['rect'], x=frame['x'] + frame['w'] + 1000)}
        away_started = time.monotonic()
        result['away_viewport'] = pan_to(away)
        assert result['away_viewport']['rect']['x'] > frame['x'] + frame['w'] + 600, 'The browser must be fully beyond the 600-document-point parking margin'
        time.sleep(1)
        result['away_native'] = capture('002-away')
        assert initial_token not in ''.join(''.join(result['away_native']['lines']).upper().split()), 'The browser body must be outside the visible viewport'
        result['away_state'] = state()
        assert result['away_state'] == expected, 'Parking must not release/reload the WKWebView or erase its JavaScript heap, even before returning'
        assert document_requests() == 1, 'Parking or offscreen agent access must not reload the fixture'
        after_away_read = run.call('view.get')['viewport']
        assert after_away_read == result['away_native']['viewport'], 'Agent access to the parked page must not move the viewport'
        result['returned_viewport'] = pan_to(before)
        result['returned_state'] = state()
        assert result['returned_state'] == expected, 'The same page and JavaScript state must survive native return'
        page('browser.eval', {'script': '(() => { if (window.browserParkingState !== ' + json.dumps(nonce) + ') throw Error("Lost browser state"); document.title = ' + json.dumps(returned_title) + '; document.querySelector("#state").textContent = ' + json.dumps(returned_token) + '; return true; })()'})
        result['returned_native'] = native_page('003-returned-live', returned_token, returned_title)
        result['elapsed_away_and_return_s'] = time.monotonic() - away_started
        assert result['elapsed_away_and_return_s'] < 120, 'This regression must return before the browser idle-release deadline'
        result['final_state'] = state()
        assert result['final_state'] == dict(expected, title=returned_title, body=returned_token), 'The returned native body must belong to the retained JavaScript page, not a saved preview'
        result['document_requests'] = document_requests()
        assert result['document_requests'] == 1, 'The browser must not perform another document load across parking and return'
        result['ok'] = True
        print('PASS browser heap state and document identity survive native parking beyond 600 points and return before 120 seconds; returned live body and native title update without reload', flush=True)
    except BaseException:
        result['error'] = traceback.format_exc()
        raise
    finally:
        cleanup_errors = []
        try:
            run.close()
        except Exception:
            cleanup_errors.append(traceback.format_exc())
        try:
            if server_started:
                server.shutdown()
            server.server_close()
            if server_started:
                server_thread.join(timeout=5)
                if server_thread.is_alive():
                    raise RuntimeError('The guest-local fixture HTTP thread did not stop within five seconds')
        except Exception:
            cleanup_errors.append(traceback.format_exc())
        if cleanup_errors:
            result.update(ok=False, cleanup_errors=cleanup_errors)
        (args.out / 'result.json').write_text(json.dumps(result, indent=2))
        if cleanup_errors:
            raise RuntimeError('\n'.join(cleanup_errors))


if __name__ == '__main__':
    main()
