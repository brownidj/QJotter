#!/usr/bin/env python3
"""Export Notefile's SVG to native icon assets. Requires rsvg-convert and magick."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/icons/notefile.svg'
DESKTOP = ROOT / 'assets/icons/notefile-desktop.svg'
SVG = '{http://www.w3.org/2000/svg}'
ET.register_namespace('', SVG[1:-1])


def render(source, destination, size):
    subprocess.run(
        ['rsvg-convert', '--width', str(size), '--height', str(size),
         '--output', str(destination), str(source)], check=True,
    )


def export_catalog(catalog, source, prefix):
    manifest_path = catalog / 'Contents.json'
    manifest = json.loads(manifest_path.read_text())
    rendered = set()
    for entry in manifest['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        filename = f'{prefix}-{size}.png'
        if size not in rendered:
            render(source, catalog / filename, size)
            rendered.add(size)
        entry['filename'] = filename
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')


def main():
    for executable in ['rsvg-convert', 'magick']:
        if not shutil.which(executable):
            raise SystemExit(f'Missing required tool: {executable}')

    # Desktop artwork uses transparent margins and its own rounded tile.
    # iOS uses the opaque square master; the OS supplies its icon mask.
    tree = ET.parse(SOURCE)
    tree.find(f'{SVG}rect').attrib.update({
        'x': '64', 'y': '64', 'width': '896', 'height': '896', 'rx': '200',
    })
    tree.find(f'{SVG}g').set('transform', 'translate(64 64) scale(0.875)')
    tree.write(DESKTOP, encoding='unicode', xml_declaration=True)

    export_catalog(
        ROOT / 'macos/Runner/Assets.xcassets/NotefileIcon.appiconset',
        DESKTOP, 'notefile-v1',
    )
    export_catalog(
        ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset',
        SOURCE, 'notefile-v1',
    )
    render(SOURCE, ROOT / 'assets/icons/notefile-1024.png', 1024)
    render(DESKTOP, ROOT / 'assets/icons/notefile-preview.png', 512)
    with tempfile.TemporaryDirectory(prefix='notefile-icons-') as directory:
        frames = []
        for size in [16, 24, 32, 48, 64, 128, 256]:
            frame = Path(directory) / f'icon-{size}.png'
            render(DESKTOP, frame, size)
            frames.append(str(frame))
        subprocess.run(
            ['magick', *frames, str(ROOT / 'windows/runner/resources/notefile-v1.ico')],
            check=True,
        )
    print('Exported macOS, iOS, and Windows icons from assets/icons/notefile.svg')


if __name__ == '__main__':
    main()
