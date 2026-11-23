#!/usr/bin/env python3
import argparse
import base64
import json
from pathlib import Path
import socket
import time


PAGE = b"""<!doctype html><canvas width=1 height=1></canvas>
<script>
const ctx = document.querySelector('canvas').getContext('2d');
window.frames = 0;
requestAnimationFrame(function paint() {
    ctx.fillStyle = '#00ff00';
    ctx.fillRect(0, 0, 1, 1);
    frames++;
    requestAnimationFrame(paint);
});
</script>"""
URL = 'data:text/html;base64,' + base64.b64encode(PAGE).decode()
SAMPLE = """(async () => {
    const start = window.frames;
    await new Promise(resolve => setTimeout(resolve, 1500));
    return {
        visibility: document.visibilityState,
        frames: window.frames - start,
        pixel: [...ctx.getImageData(0, 0, 1, 1).data]
    };
})()"""


def request(path, method, **params):
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(10)
        channel.connect(str(path))
        channel.sendall((json.dumps({'id': method, 'method': method, 'params': params}) + '\n').encode())
        with channel.makefile('rb') as stream:
            reply = json.loads(stream.readline())
    if not reply.get('ok', 'result' in reply):
        raise RuntimeError(f'{method}: {reply.get("error")}')
    return reply['result']


def main():
    parser = argparse.ArgumentParser(description='Check a driven browser across a real macOS Space switch.')
    parser.add_argument('home', type=Path, help='Disposable scripts/dev.sh home with an empty board')
    home = parser.parse_args().home
    if not (home / 'easl.app').is_dir():
        parser.error('Use a disposable scripts/dev.sh home.')
    api = home / 'easl.sock'
    board = request(api, 'board.get')
    if board['objects']:
        parser.error('Start with an empty scratch board.')
    board_id = board['board']
    view = request(api, 'view.get', board=board_id)
    if not view['visible']:
        parser.error('The scratch board must start on the active Space.')
    rect = view['viewport']['rect']
    tiles = []

    def sample():
        obj = request(api, 'object.create', board=board_id, type='browser',
                      frame={'x': rect['x'] + rect['w'] + 6000, 'y': rect['y'], 'w': 450, 'h': 250},
                      props={'url': URL})['object']['id']
        tiles.append(obj)
        page = request(api, 'object.get', id=obj)['page']
        if page['loaded'] or page['visibility'] != 'released':
            raise RuntimeError(f'Browser was not cold: {page}')
        return request(home / 'cmux.sock', 'browser.eval', surface_id=obj, script=SAMPLE)['value']

    def check(label, minimum_frames):
        result = sample()
        print(f'{label}: {json.dumps(result)}', flush=True)
        if (result['visibility'] != 'visible' or result['frames'] < minimum_frames
                or result['pixel'] != [0, 255, 0, 255]):
            raise SystemExit(f'FAIL: The driven page did not paint {label} ({minimum_frames} callbacks required).')
        return result['frames']

    try:
        before = check('before the switch', 1)
        print('READY: Switch to another macOS Space without hiding or minimizing easl.', flush=True)
        deadline = time.monotonic() + 20
        while request(api, 'view.get', board=board_id)['visible']:
            if time.monotonic() >= deadline:
                raise SystemExit('FAIL: The scratch board never left the screen.')
            time.sleep(0.1)
        check('after the switch', max(1, before // 2))
        print('PASS: A cold driven page paints while its board is on another Space.')
    finally:
        for tile in tiles:
            request(api, 'object.delete', id=tile)


if __name__ == '__main__':
    main()
