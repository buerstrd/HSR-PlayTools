"""Build the native module without modifying the installed game."""
import argparse
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['build'])
parser.parse_args()
clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
flags = [clang, '-target', 'arm64-apple-ios14.0-macabi', '-isysroot', sdk,
         '-O2', '-Wall', '-Wextra', '-Werror', '-fblocks', '-lobjc']
version = (root / 'VERSION').read_text().strip()
if not version or any(ord(c) < 32 for c in version):
    raise RuntimeError('Invalid version metadata')
flags.append('-DHSR_DISPLAY_VERSION=' + json.dumps(version))
output = root / 'HSRPlayTools.dylib'
source = (root / 'HSRPlayTools.luau').read_bytes()
if not source:
    raise RuntimeError('Lua source is empty')
with tempfile.TemporaryDirectory(prefix='hsr-plugin-build-') as temporary:
    include = pathlib.Path(temporary)
    # A trailing NUL matches the C string representation; runtime excludes it.
    rows = [','.join(str(b) for b in source[i:i+24]) for i in range(0, len(source), 24)]
    (include / 'embedded_lua.h').write_text(
        'static const unsigned char embedded_lua[] = {\n' + ',\n'.join(rows) + ',0\n};\n')
    subprocess.run(flags + ['-I', str(include), '-dynamiclib',
        '-install_name', '@rpath/HSRPlayTools.dylib',
        str(root / 'HSRPlayTools.c'), '-o', str(output)], check=True)
if source + b'\0' not in output.read_bytes():
    raise RuntimeError('Embedded Lua verification failed')
print(f'Completed: {output}; embedded Lua: {len(source)} bytes')
