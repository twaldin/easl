#!/usr/bin/env python3
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback


def main():
    parser = argparse.ArgumentParser(description='Verify saved and deferred tile previews in a real macOS viewer.')
    parser.add_argument('--checkout', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--window-helper', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    case_names = ('saved_browser_preview', 'distant_cold_starts_near', 'cancelled_cold_restarts_near', 'first_fit_500', 'first_fit_1000')
    parser.add_argument('--cases', default=','.join(case_names), help='Comma-separated native cases; default runs all five')
    args = parser.parse_args()
    selected_cases = args.cases.split(',')
    if not selected_cases or any(name not in case_names for name in selected_cases):
        parser.error('--cases must name the documented native cases')
    if sys.platform != 'darwin':
        parser.error('Run only inside the claimed GUI guest')
    args.out.mkdir(parents=True)
    spec = importlib.util.spec_from_file_location('scale', args.checkout / 'scripts/perf-scale.py')
    scale = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scale)
    guest_model = scale.require_guest()
    scratch = Path(tempfile.mkdtemp(prefix='etp-', dir='/tmp'))
    home, root = scratch / 'v', scratch / 'board'
    root.mkdir()
    home.mkdir()
    (home / 'get-started.json').write_text('{"dismissed":true}')
    environment = dict(os.environ, EASL_DEV_HOME=str(home), EASL_DEV_APP=str(args.app), EASL_DEV_FRAME='0 0 1000 500')
    for key in ('EASL_BOARD_ID', 'EASL_TILE_ID'):
        environment.pop(key, None)
    events = []
    lock = threading.Lock()
    gates = {name: threading.Event() for name in ('cold', 'cancel')}
    records = {'app': str(args.app), 'binary_sha256': hashlib.sha256((args.app / 'Contents/MacOS/Easl').read_bytes()).hexdigest(), 'guest_model': guest_model, 'scratch': str(scratch), 'cases': {}}
    failures = []
    cleanup_errors = []
    custom_started = False
    board = None
    pid = None
    capture_number = 0

    def record(kind, **values):
        with lock:
            events.append(dict(kind=kind, time=time.monotonic(), **values))
            (args.out / 'http-events.json').write_text(json.dumps(events, indent=2))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_arguments):
            pass

        def do_GET(self):
            name = self.path.split('?', 1)[0].strip('/')
            record('request', path=name)
            try:
                if name == 'live':
                    body = b'<!doctype html><title>Browser control</title><body style="margin:40px;background:#b8efce;font:bold 128px monospace">KEEPALPHA</body>'
                    content_type = 'text/html'
                elif name in gates:
                    if not gates[name].wait(30):
                        self.send_error(408, 'The test did not release the image gate')
                        record('gate-timeout', path=name)
                        return
                    token = {'cold': 'NEARBETA', 'cancel': 'AGAINDELTA'}[name]
                    body = ('<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="1100"><rect width="2400" height="1100" fill="#c4e6ff"/><text x="100" y="300" font-family="monospace" font-size="160" font-weight="bold">' + token + '</text></svg>').encode()
                    content_type = 'image/svg+xml'
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                record('response', path=name)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as error:
                record('disconnected', path=name, error=type(error).__name__)
            finally:
                record('finished', path=name)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever)
    server_thread.start()
    records['http_port'] = server.server_port
    url = 'http://127.0.0.1:' + str(server.server_port)

    def dev(*arguments):
        return scale.command(args.checkout / 'scripts/dev.sh', *arguments, env=environment)

    def call(method, params=None):
        parameters = dict(params or {})
        if method in ('object.create', 'view.get'):
            parameters['board'] = board
        return scale.rpc(home / 'easl.sock', method, parameters)

    def viewport(instance=None):
        return (instance.call('view.get') if instance else call('view.get'))['viewport']

    def until(description, observe, predicate, seconds=15):
        deadline = time.monotonic() + seconds
        while True:
            value = observe()
            if predicate(value):
                return value
            if time.monotonic() >= deadline:
                raise AssertionError(description + ': ' + repr(value))
            time.sleep(0.05)

    def capture(label, instance=None):
        nonlocal capture_number
        capture_home = instance.home if instance else home
        capture_pid = instance.pid if instance else pid
        windows = json.loads(scale.command(args.window_helper, capture_pid))
        window = max(windows, key=lambda item: item['kCGWindowBounds']['Width'] * item['kCGWindowBounds']['Height'])
        image = args.out / ('{:03d}-{}.png'.format(capture_number, label))
        capture_number += 1
        receipt = scale.native.capture(capture_home, window['kCGWindowNumber'], image, accessibility=True)
        text = scale.frame_text(args.window_helper, image)
        return {'image': str(image), 'capture_id': receipt['capture_id'], 'viewport': viewport(instance), 'lines': text['lines']}

    def contains(image, token):
        text = ''.join(''.join(image['lines']).split()).upper()
        return token in text

    def pixel_token(label, token, seconds=15, instance=None):
        return until('Native pixels never showed ' + token, lambda: capture(label, instance), lambda image: contains(image, token), seconds)

    def pan_to(x, y, instance=None):
        input_event = instance.dev if instance else dev
        for _ in range(4):
            view = viewport(instance)
            rect, zoom = view['rect'], view['zoom']
            dx, dy = (x - rect['x']) * zoom, (y - rect['y']) * zoom
            if abs(dx) < 2 and abs(dy) < 2:
                return view
            input_event('input', 'drag', 20, 220, 20 - dx, 220 - dy, '--middle')
            time.sleep(0.15)
            assert abs(viewport(instance)['zoom'] - zoom) < 0.0001, 'Board pan changed magnification'
        view = viewport(instance)
        assert abs(view['rect']['x'] - x) * view['zoom'] < 3 and abs(view['rect']['y'] - y) * view['zoom'] < 3, view
        return view

    def show(frame, instance=None):
        view = viewport(instance)
        return pan_to(frame['x'] - 80 / view['zoom'], frame['y'] - 90 / view['zoom'], instance)

    def requests(name):
        with lock:
            return sum(event['kind'] == 'request' and event['path'] == name for event in events)

    def create(kind, props, frame):
        return call('object.create', {'type': kind, 'props': props, 'frame': frame})['object']

    def delete(obj):
        call('object.delete', {'id': obj['id']})

    def card_zoom():
        dev('input', 'mainmenu', 'View/Actual Size')
        offset = (home / 'app.log').stat().st_size
        dev('input', 'magnify', 20, 220, -0.5, '--repeat', 2, '--interval', 100, '--realtime')
        delivery = until('Native pinch did not finish its phased real-time burst',
                         lambda: (home / 'app.log').read_text(errors='replace')[offset:],
                         lambda text: 'DevInput.delivery: scheduled 2 ' in text and 'realtime 1' in text)
        records.setdefault('completed_pinches', []).append(delivery)
        time.sleep(2)
        view = viewport()
        assert 0.20 <= view['zoom'] < 0.27, view
        return view

    def browser_preview():
        dev('input', 'mainmenu', 'View/Actual Size')
        rect = viewport()['rect']
        frame = {'x': rect['x'] + 60, 'y': rect['y'] + 90, 'w': 2400, 'h': 1200}
        browser = create('browser', {'title': 'Saved browser control', 'url': url + '/live'}, frame)
        try:
            live = pixel_token('browser-live', 'KEEPALPHA')
            time.sleep(1.5)
            card_zoom()
            show(frame)
            time.sleep(1.5)
            before = pixel_token('browser-card-before', 'KEEPALPHA')
            away = pan_to(frame['x'] + 20000, frame['y'] + 20000)
            capture('browser-away')
            returned = show(frame)
            time.sleep(1)
            after = capture('browser-card-returned')
            records['cases']['saved_browser_preview'] = {'live': live, 'before': before, 'away': away, 'returned': returned, 'after': after}
            assert contains(after, 'KEEPALPHA'), 'A completed browser preview lost its body pixels after far/near without going live'
        finally:
            delete(browser)

    def cold_preview(name, token, cancel):
        card_zoom()
        rect = viewport()['rect']
        frame = {'x': rect['x'] + rect['w'] + 15000, 'y': rect['y'], 'w': 2400, 'h': 1200}
        html = '<!doctype html><style>html,body{margin:0}</style><img width="2400" height="1100" src="' + url + '/' + name + '">'
        obj = create('html', {'title': 'Cold image control', 'html': html, 'allowNetwork': ['127.0.0.1:' + str(server.server_port)]}, frame)
        result = {'object': obj, 'before_near': viewport()}
        records['cases'][name] = result
        try:
            distant = result['before_near']['rect']
            assert obj['frame']['x'] > distant['x'] + distant['w'] + 10000, 'Cold tile was not actually distant'
            time.sleep(2)
            result['requests_while_distant'] = requests(name)
            assert result['requests_while_distant'] == 0, 'Distant cold content loaded before entering proximity'
            result['first_near'] = show(frame)
            until('Near cold image was never requested', lambda: requests(name), lambda count: count >= 1)
            result['blocked'] = capture(name + '-blocked')
            assert not contains(result['blocked'], token), 'The image appeared before its HTTP gate was released'
            if cancel:
                result['far_while_inflight'] = pan_to(frame['x'] + 20000, frame['y'] + 20000)
                capture(name + '-cancelled-away')
                time.sleep(0.25)
                result['second_near'] = show(frame)
                result['requests_after_reentry'] = until('Cancelled cold preview did not restart on reentry', lambda: requests(name), lambda count: count >= 2)
            gates[name].set()
            result['shown'] = pixel_token(name + '-shown', token)
            result['requests_total'] = requests(name)
        finally:
            gates[name].set()
            delete(obj)

    def stop_custom():
        nonlocal board, pid, custom_started
        if not custom_started:
            return
        if board:
            try:
                scale.rpc(home / 'easl.sock', 'board.close', {'board': board, 'endSessions': True})
                board = None
            except Exception:
                cleanup_errors.append(traceback.format_exc())
        try:
            dev('stop')
            custom_started = False
            pid = None
        except Exception:
            cleanup_errors.append(traceback.format_exc())
        scale.native.end_session()

    def first_fit(count):
        stop_custom()
        assert not cleanup_errors, 'The preceding viewer did not cleanly stop'
        output = args.out / ('fixture-' + str(count))
        output.mkdir()
        options = argparse.Namespace(fixtures=scratch / 'fixtures', ssh=None, easld=None, window_helper=args.window_helper)
        run = scale.Run(options, args.app, count, 'local', output)
        result = {}
        records['cases']['first_fit_' + str(count)] = result
        try:
            fixture = run.start()
            terminals = [obj for obj in fixture['objects'] if obj['type'] == 'terminal']
            assert len(fixture['objects']) == count and len(terminals) == 8
            streams = {}
            for terminal in terminals:
                streams[terminal['id']] = scale.rpc(run.socket, 'agent.read', {'target': terminal['id'], 'lines': 10})
                assert 'sequence=' in json.dumps(streams[terminal['id']]), 'Fixture terminal did not produce output'
            (output / 'streams.json').write_text(json.dumps(streams, indent=2))
            run.dev('input', 'mainmenu', 'View/Actual Size')
            rect = viewport(run)['rect']
            frame = {'x': rect['x'] + 60, 'y': rect['y'] + 90, 'w': 2400, 'h': 1200}
            browser = run.call('object.create', {'type': 'browser', 'props': {'title': 'Loaded scale browser', 'url': url + '/live?size=' + str(count)}, 'frame': frame})['object']
            result['browser'] = browser
            result['live'] = pixel_token('fit-' + str(count) + '-live', 'KEEPALPHA', instance=run)
            time.sleep(1.5)
            metrics = lambda: scale.rpc(run.home / 'easl.sock', 'app.metrics')
            browser_cards = lambda value: value.get('counters', {}).get('card.latency.BrowserTile', {}).get('total', {}).get('n', 0)
            result['metrics_before'] = metrics()
            completed_before = browser_cards(result['metrics_before'])
            (output / 'fixture-plus-browser.json').write_text(json.dumps(run.call('board.get'), indent=2))
            run.dev('input', 'mainmenu', 'View/Zoom to Fit')
            result['first_fit'] = capture('fit-' + str(count) + '-first-fit', run)
            result['metrics_after_browser_card'] = until('Outgoing browser card did not complete', metrics,
                                                         lambda value: browser_cards(value) > completed_before, seconds=90)
            for _ in range(3):
                zoom = viewport(run)['zoom']
                if 0.22 <= zoom <= 0.26:
                    break
                amount = (0.24 / zoom) ** 0.25 - 1
                offset = len(run.log())
                run.dev('input', 'magnify', 20, 220, amount, '--repeat', 4, '--interval', 100, '--realtime')
                delivery = until('Readable card pinch did not finish', lambda: run.log()[offset:],
                                 lambda text: 'DevInput.delivery: scheduled 4 ' in text and 'realtime 1' in text)
                result.setdefault('completed_pinches', []).append(delivery)
            assert 0.20 <= viewport(run)['zoom'] < 0.27, viewport(run)
            result['card_returned'] = show(frame, run)
            result['after'] = capture('fit-' + str(count) + '-completed-browser-card', run)
            assert contains(result['after'], 'KEEPALPHA'), 'First Zoom to Fit lost the loaded browser preview body after card completion'
        finally:
            try:
                run.close()
            except Exception:
                cleanup_errors.append(traceback.format_exc())
                raise

    try:
        exercises = [('saved_browser_preview', browser_preview), ('distant_cold_starts_near', lambda: cold_preview('cold', 'NEARBETA', False)), ('cancelled_cold_restarts_near', lambda: cold_preview('cancel', 'AGAINDELTA', True)), ('first_fit_500', lambda: first_fit(500)), ('first_fit_1000', lambda: first_fit(1000))]
        if any(name in selected_cases for name in case_names[:3]):
            custom_started = True
            dev('start', root)
            pid = int((home / 'pid').read_text())
            records['pid'] = pid
            dev('input', 'idle', 'off')
            active = scale.native_json(args.window_helper, args.out / 'activation', '--activate', pid)
            assert active['pid'] == pid and active['isActive']
            board = scale.rpc(home / 'easl.sock', 'board.open', {'root': str(root), 'select': True})['board']
            create('shape', {'kind': 'rect', 'text': 'Far anchor'}, {'x': 80000, 'y': 80000, 'w': 100, 'h': 100})
        for name, exercise in exercises:
            if name not in selected_cases:
                continue
            try:
                exercise()
                records['cases'].setdefault(name, {})['ok'] = True
                print('PASS ' + name, flush=True)
            except Exception:
                error = traceback.format_exc()
                records['cases'].setdefault(name, {})['ok'] = False
                records['cases'][name]['error'] = error
                failures.append(name)
                print('FAIL ' + name + '\n' + error, flush=True)
            if cleanup_errors:
                break
    finally:
        for gate in gates.values():
            gate.set()
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)
        stop_custom()
        scale.native.end_session()
        if (home / 'app.log').exists():
            shutil.copy2(home / 'app.log', args.out / 'app.log')
        records['failures'] = failures
        records['cleanup_errors'] = cleanup_errors
        records['selected_cases'] = selected_cases
        records['ok'] = all(records['cases'].get(name, {}).get('ok') for name in selected_cases) and not cleanup_errors and not server_thread.is_alive()
        (args.out / 'result.json').write_text(json.dumps(records, indent=2))
        if not cleanup_errors:
            shutil.rmtree(scratch)
    if not records['ok']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
