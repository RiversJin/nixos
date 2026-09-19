"""Daily anime wallpaper and desktop palette; all state is local and replaceable."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from PIL import Image, ImageStat

API = 'https://wallhaven.cc/api/v1/search'
OUTPUTS = ('eDP-1',)
PRIMARY = 'eDP-1'
RECENT_LIMIT = 14
FILES = ('niri.kdl', 'mako.conf', 'swaylock.conf')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def fetch(url, limit):
    # curl works reliably on this host's TLS/network route; keep bounded downloads.
    data = subprocess.run([
        'curl', '--fail', '--location', '--silent', '--show-error',
        '--connect-timeout', '10', '--max-time', '45', '--retry', '2',
        '--retry-delay', '1', '--max-filesize', str(limit),
        '--user-agent', 'niri-daily-wallpaper/1.0', url,
    ], check=True, stdout=subprocess.PIPE).stdout
    if len(data) > limit:
        raise ValueError('Download exceeds size limit')
    return data


def scenery_candidates():
    # Union scenic tags from the highest-ranked pages; enough variety for two screens.
    candidates = {}
    for term in ('landscape', 'scenery'):
        params = dict(q=term, categories='010', purity='100', atleast='3840x2160',
                      ratios='16x9', sorting='toplist', topRange='1y')
        data = json.loads(fetch(API + '?' + urllib.parse.urlencode(params), 2 * 1024 * 1024))
        for item in data['data']:
            candidates[item['id']] = item
        for page in range(2, min(3, data.get('meta', {}).get('last_page', 1)) + 1):
            params['page'] = page
            more = json.loads(fetch(API + '?' + urllib.parse.urlencode(params), 2 * 1024 * 1024))
            for item in more['data']:
                candidates[item['id']] = item
    return list(candidates.values())


def choose_image(state, old, items):
    recent = set(old.get('recent_ids', []))
    items = [x for x in items if x.get('purity') == 'sfw' and x.get('category') == 'anime'
             and re.fullmatch(r'[a-z0-9]{6}', x.get('id', '')) and x['id'] not in recent]
    secrets.SystemRandom().shuffle(items)
    cache = state / 'images'
    cache.mkdir(exist_ok=True)
    errors = []
    for item in items[:4]:
        try:
            url = urllib.parse.urlparse(item['path'])
            if url.scheme != 'https' or url.hostname != 'w.wallhaven.cc':
                raise ValueError('Unexpected image host')
            suffix = Path(url.path).suffix.lower()
            if suffix not in ('.png', '.jpg', '.jpeg', '.webp'):
                raise ValueError('Unsupported wallpaper format')
            image = cache / (item['id'] + suffix)
            if not image.exists():
                data = fetch(item['path'], 40 * 1024 * 1024)
                temporary = image.with_suffix('.download')
                temporary.write_bytes(data)
                try:
                    with Image.open(temporary) as im:
                        im.verify()
                    with Image.open(temporary) as im:
                        if im.width < 3840 or im.height < 2160 or abs(im.width / im.height - 16 / 9) > .03:
                            raise ValueError('Wallpaper does not meet 4K landscape requirements')
                    temporary.replace(image)
                finally:
                    temporary.unlink(missing_ok=True)
            return image, {'id': item['id'], 'source': item['url'], 'download': item['path'],
                           'date': dt.date.today().isoformat(),
                           'recent_ids': ([item['id']] + old.get('recent_ids', []))[:RECENT_LIMIT]}
        except Exception as error:
            errors.append(str(error))
    raise RuntimeError('No usable wallpaper: ' + '; '.join(errors))


def palette(image):
    data = json.loads(run('matugen', 'image', str(image), '--dry-run', '--source-color-index', '0',
                          '-m', 'dark', '-j', 'hex', stdout=subprocess.PIPE).stdout)
    colors = {k: v['dark']['color'] for k, v in data['colors'].items()}
    if not all(re.fullmatch(r'#[0-9a-fA-F]{6}', v) for v in colors.values()):
        raise ValueError('Invalid generated palette')
    with Image.open(image) as im:
        im = im.convert('RGB')
        im.thumbnail((64, 64))
        mean = ImageStat.Stat(im).mean
        brightness = (.2126 * mean[0] + .7152 * mean[1] + .0722 * mean[2]) / 255
    return colors, max(.48, min(.82, .40 + brightness * .48))


def rgb(color):
    return ', '.join(str(int(color[i:i+2], 16)) for i in (1, 3, 5))


def render(text, colors, alpha, image):
    # Single-pass substitutions preserve syntax and alpha values in each base file.
    roles = {
        '91b8ed': 'primary', '8bd5ca': 'primary', 'b6c8dc': 'secondary',
        'dce5ef': 'on_surface', 'f0f5f9': 'on_surface',
        '91a4b9': 'on_surface_variant', '8193a8': 'on_surface_variant',
        '101923': 'surface', '101a28': 'surface', '14202f': 'surface',
        '10212c': 'surface', '293e50': 'surface_container_high',
        '344356': 'outline_variant', '344c68': 'primary_container',
        '26394e': 'surface_container_high', '506780': 'outline',
        '719dcc': 'primary', 'ed8796': 'error', 'edb69b': 'tertiary',
        '402536': 'error_container',
    }
    token = re.compile('|'.join(roles), re.IGNORECASE)
    text = token.sub(lambda m: colors[roles[m.group().lower()]][1:], text)
    text = re.sub(r'rgba\(12, 20, 30, 0\.60\)', f'rgba({rgb(colors["surface"])}, {max(.60, alpha):.2f})', text)
    text = re.sub(r'rgba\(18, 27, 39, 0\.48\)', f'rgba({rgb(colors["surface"])}, {alpha:.2f})', text)
    text = re.sub(r'rgba\(18, 29, 42, 0\.30\)', f'rgba({rgb(colors["surface_container"])}, 0.30)', text)
    text = text.replace('--noti-bg: 18, 29, 42;', f'--noti-bg: {rgb(colors["surface"])};')
    text = text.replace('--noti-bg-alpha: 0.58;', f'--noti-bg-alpha: {max(.58, alpha):.2f};')
    for source in ('145, 184, 237', '180, 203, 228', '160, 190, 220'):
        text = text.replace(source, rgb(colors['primary']))
    text = text.replace('rgba(16, 26, 40, 0.65)',
                        f'rgba({rgb(colors["surface_container_high"])}, {max(.68, min(.78, alpha)):.2f})')
    # Fuzzel uses RGBA hex without a leading #.
    text = re.sub(r'(?m)^background=[0-9a-fA-F]{8}$',
                  'background=' + colors['surface'][1:] + f'{round(max(.65, alpha)*255):02x}', text)
    text = re.sub(r'(?m)^image=.*$', 'image=' + str(image), text)
    return text


def activate(state, base, images, metadata):
    image = images[PRIMARY]
    colors, alpha = palette(image)
    generation = Path(tempfile.mkdtemp(prefix='theme-', dir=state))
    try:
        for name in FILES:
            rendered = render((base / name).read_text(), colors, alpha, image)
            if name == 'swaylock.conf':
                rendered = re.sub(r'(?m)^image=.*$',
                                  'image=' + str(image) + '\n' + '\n'.join('image=' + output + ':' + str(images[output])
                                            for output in OUTPUTS), rendered)
            (generation / name).write_text(rendered)
        (generation / 'wallpaper').symlink_to(image)
        for output in OUTPUTS:
            (generation / ('wallpaper-' + output)).symlink_to(images[output])
        metadata = dict(metadata, palette=colors, surface_opacity=round(alpha, 2))
        (generation / 'metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
        run('niri', 'validate', '-c', str(generation / 'niri.kdl'))
        temporary = state / 'current.new'
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(generation.name)
        temporary.replace(state / 'current')
    except Exception:
        shutil.rmtree(generation)
        raise
    # Bound only our generated cache; keep current and previous themes for recovery.
    generations = sorted(state.glob('theme-*'), key=lambda p: p.stat().st_mtime, reverse=True)
    for old in generations[2:]:
        if old.is_dir():
            shutil.rmtree(old)
    protected = {p.resolve() for p in [p for g in generations[:2] for p in g.glob('wallpaper*')] if p.exists()}
    cache = state / 'images'
    if cache.exists():
        images = sorted((p for p in cache.iterdir() if p.suffix in ('.png', '.jpg', '.jpeg', '.webp')),
                        key=lambda p: p.stat().st_mtime, reverse=True)
        for old in images[RECENT_LIMIT:]:
            if old.resolve() not in protected:
                old.unlink()
    return metadata


def reload_desktop(state):
    # A lingering user manager can survive logout; only touch an active niri session.
    active = subprocess.run(['systemctl', '--user', 'is-active', '--quiet', 'niri.service']).returncode == 0
    if not active:
        return
    commands = [
        ['niri', 'msg', 'action', 'load-config-file', '--path', str(Path.home() / '.config/niri/config.kdl')],
        ['systemctl', '--user', 'try-restart', 'niri-wallpaper.service', 'niri-bar.service'],
        ['makoctl', 'reload'],
    ]
    for command in commands:
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode:
            print('Reload warning: ' + result.stderr.strip(), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('init', 'update', 'next', 'wallpaper', 'status'))
    args = parser.parse_args()
    state = Path(os.environ.get('NIRI_DAILY_STATE', str(Path.home() / '.local/state/niri-daily')))
    base = Path(os.environ['NIRI_THEME_BASE'])
    fallback = Path(os.environ['NIRI_FALLBACK_IMAGE'])
    state.mkdir(parents=True, exist_ok=True)
    current = state / 'current'
    if args.action == 'wallpaper':
        image = current / 'wallpaper' if (current / 'wallpaper').exists() else fallback
        command = ['swaybg', '-i', str(image), '-m', 'fill']
        for output in OUTPUTS:
            output_image = current / ('wallpaper-' + output)
            if output_image.exists():
                command += ['-o', output, '-i', str(output_image), '-m', 'fill']
        os.execvp(command[0], command)
    if args.action == 'status':
        print(json.dumps(read_json(current / 'metadata.json', {}), ensure_ascii=False, indent=2))
        return
    with (state / 'update.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old = read_json(current / 'metadata.json', {})
        image = (current / 'wallpaper').resolve() if (current / 'wallpaper').exists() else fallback
        images = {output: ((current / ('wallpaper-' + output)).resolve()
                           if (current / ('wallpaper-' + output)).exists() else image)
                  for output in OUTPUTS}
        if args.action == 'init':
            activate(state, base, images, old)
            return
        today = dt.date.today().isoformat()
        if (args.action == 'update' and old.get('date') == today
                and old.get('selection_style') == 'anime-scenery'
                and all(old.get('outputs', {}).get(o, {}).get('id') for o in OUTPUTS)
                and len({old['outputs'][o]['id'] for o in OUTPUTS}) == len(OUTPUTS)):
            print('Wallpaper already selected for ' + today)
            return
        try:
            candidates = scenery_candidates()
            output_metadata = {}
            recent = old
            for output in OUTPUTS:
                images[output], selected = choose_image(state, recent, candidates)
                output_metadata[output] = {k: selected[k] for k in ('id', 'source', 'download')}
                recent = selected
            metadata = dict(output_metadata[PRIMARY], outputs=output_metadata,
                            date=today, recent_ids=recent['recent_ids'],
                            selection_style='anime-scenery', palette_output=PRIMARY)
            applied = activate(state, base, images, metadata)
        except Exception as error:
            print('Keeping the previous wallpaper: ' + str(error), file=sys.stderr)
            if not (current / 'wallpaper').exists():
                activate(state, base, {o: fallback for o in OUTPUTS}, old)
            raise SystemExit(1)
        reload_desktop(state)
        for output in OUTPUTS:
            print(output + ': ' + applied['outputs'][output]['source'])


if __name__ == '__main__':
    main()
