#!/usr/bin/env python3
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import time
import traceback


def main():
    parser = argparse.ArgumentParser(description='Verify offscreen tile return, native controls, and whole-board export in a claimed GUI guest.')
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
    result = {'ok': False}

    def capture(name):
        windows = json.loads(scale.command(args.window_helper, run.pid))
        window = max(windows, key=lambda value: value['kCGWindowBounds']['Width'] * value['kCGWindowBounds']['Height'])
        image = args.out / (name + '.png')
        receipt = scale.native.capture(run.home, window['kCGWindowNumber'], image, accessibility=True)
        text = scale.frame_text(args.window_helper, image)
        return {'window': window['kCGWindowNumber'], 'capture_id': receipt['capture_id'], 'elements': receipt['elements'],
                'lines': text['lines'], 'viewport': run.call('view.get')['viewport']}

    def contains(snapshot, token):
        return ''.join(token.upper().split()) in ''.join(''.join(snapshot['lines']).upper().split())

    def at_viewport(current, target):
        return current['zoom'] == target['zoom'] and all(
            abs(current['rect'][key] - target['rect'][key]) <= .5 / target['zoom']
            for key in ('x', 'y', 'w', 'h'))

    def restore(target):
        run.dev('input', 'mainmenu', 'View/Actual Size')
        time.sleep(.5)
        for _ in range(6):
            current = run.call('view.get')['viewport']
            if at_viewport(current, target):
                return
            assert current['zoom'] == target['zoom'] == 1, current
            dx = target['rect']['x'] - current['rect']['x']
            dy = target['rect']['y'] - current['rect']['y']
            run.dev('input', 'drag', 20, 220, 20 - dx, 220 - dy, '--middle')
            time.sleep(.2)
        current = run.call('view.get')['viewport']
        assert at_viewport(current, target), {'message': 'Native return must restore the viewport within one backing pixel', 'current': current, 'target': target}

    try:
        board = run.start()
        run.dev('input', 'mainmenu', 'View/Actual Size')
        time.sleep(.5)
        before = run.call('view.get')['viewport']
        note = next(obj for obj in board['objects'] if obj['type'] == 'note')
        frame = {'x': before['rect']['x'] + 80, 'y': before['rect']['y'] + 100, 'w': 420, 'h': 220}
        scale.rpc(run.socket, 'object.update', {'id': note['id'], 'frame': frame, 'z': 9999,
                                              'props': {'title': 'Parked title', 'markdown': 'VISIBLEBODYALPHA'}})
        time.sleep(.5)
        result['before'] = capture('001-before')
        assert contains(result['before'], 'Parked title') and contains(result['before'], 'VISIBLEBODYALPHA')
        scale.rpc(run.socket, 'object.update', {'id': note['id'], 'props': {'zoom': .25}})
        time.sleep(2)
        offset = len(run.log())
        run.dev('input', 'magnify', 600, 300, .001, '--repeat', 2, '--interval', 2000, '--realtime')
        time.sleep(.3)
        result['during_pinch'] = capture('001-during-pinch')
        assert contains(result['during_pinch'], 'Parked title'), 'Pinching must retain the native title pixels'
        scale.wait_for(lambda: 'DevInput.delivery: scheduled 2 ' in run.log()[offset:])
        scale.rpc(run.socket, 'object.update', {'id': note['id'], 'props': {'zoom': 1}})
        restore(before)
        time.sleep(.5)
        result['pinch'] = run.gesture('zoom')
        assert result['pinch']['moved'] and result['pinch']['input_delivery']['realtime'] == 1
        restore(before)
        time.sleep(.5)
        result['after_pinch'] = capture('002-after-pinch')
        assert contains(result['after_pinch'], 'Parked title') and contains(result['after_pinch'], 'VISIBLEBODYALPHA')
        run.dev('input', 'scroll', 600, 300, -2000, 0, '--mods', 'cmd')
        time.sleep(.5)
        away = run.call('view.get')['viewport']
        assert away['rect']['x'] > frame['x'] + frame['w'] + 600, away
        scale.rpc(run.socket, 'object.update', {'id': note['id'], 'props': {'title': 'Returned title', 'markdown': 'VISIBLEBODYBETA'}})
        restore(before)
        time.sleep(.5)
        result['returned'] = capture('003-returned')
        assert at_viewport(result['returned']['viewport'], before)
        assert contains(result['returned'], 'Returned title') and contains(result['returned'], 'VISIBLEBODYBETA')
        assert not contains(result['returned'], 'VISIBLEBODYALPHA'), 'Returning live content must not keep stale body pixels'
        run.dev('input', 'scroll', 600, 300, -2000, 0, '--mods', 'cmd')
        time.sleep(.5)
        viewport = run.call('view.get')['viewport']
        ids = [obj['id'] for obj in board['objects']]
        rendered = run.call('view.render', {'target': ids, 'scale': .15, 'inline': True, 'timeoutMs': 60000})
        image = base64.b64decode(rendered.pop('data'), validate=True)
        assert image.startswith(b'\x89PNG\r\n\x1a\n')
        assert {obj['id'] for obj in rendered['objects']} == set(ids)
        assert all(obj['state'] == 'rendered' for obj in rendered['objects']), rendered['objects']
        assert run.call('view.get')['viewport'] == viewport, 'Export must not move the viewport'
        (args.out / 'whole.png').write_bytes(image)
        (args.out / 'render.json').write_text(json.dumps(rendered, indent=2))
        restore(before)
        current = capture('004-before-close')
        scale.native.press_close(run.home, current['window'], args.out / '005-native-close.png', 'Close Returned title')
        scale.wait_for(lambda: note['id'] not in {obj['id'] for obj in run.call('board.get')['objects']})
        result['after_close'] = capture('006-after-close')
        assert not any(element.get('label') == 'Close Returned title' for element in result['after_close']['elements'])
        result['ok'] = True
        print('PASS native title and body return, offscreen updates, whole-board export, and native Close', flush=True)
    except BaseException:
        result['error'] = traceback.format_exc()
        raise
    finally:
        try:
            run.close()
        except BaseException:
            result.update(ok=False, cleanup_error=traceback.format_exc())
            raise
        finally:
            (args.out / 'result.json').write_text(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
