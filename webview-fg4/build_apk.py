#!/usr/bin/env python3
"""Build a signed offline APK with pinned SDK tools; no Gradle/JDK required.

Requirements: Linux x86_64, Python 3.9+, Java 17+, and keytool. The first run
downloads the Android SDK tools/platform and the Eclipse Java compiler.
"""
from __future__ import annotations
import argparse
import configparser
import hashlib
import os
from pathlib import Path
import platform
import secrets
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
ARTIFACT = 'ElementalSwarm_11.11.9_framegen4.apk'
DOWNLOADS = (
    ('build-tools.zip', 'https://dl.google.com/android/repository/build-tools_r36_linux.zip',
     '5d9ac77fb6ff43d9da518a337b4fcf8f9097113df531d99ccefe80ef7ce8250b', 'sdk-build'),
    ('platform.zip', 'https://dl.google.com/android/repository/platform-36_r02.zip',
     '37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e', 'sdk-platform'),
    ('ecj.jar', 'https://repo.maven.apache.org/maven2/org/eclipse/jdt/ecj/3.40.0/ecj-3.40.0.jar',
     '05cc22a24e7982970f63a405fc6c820bc80b806f27f3c5a6236fc475f8f7152b', None),
)


def run(command, env=None):
    subprocess.run([str(x) for x in command], check=True, cwd=ROOT, env=env)


def prepare_tools(directory):
    directory.mkdir(parents=True, exist_ok=True)
    for name, url, digest, extracted in DOWNLOADS:
        archive=directory/name
        if not archive.exists():
            print('Downloading',name,flush=True)
            temporary=archive.with_suffix(archive.suffix+'.part')
            urllib.request.urlretrieve(url,temporary)
            temporary.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=digest:
            raise RuntimeError('Checksum mismatch: '+name)
        if extracted and not (directory/extracted).exists():
            with zipfile.ZipFile(archive) as z:z.extractall(directory/extracted)
    tools=directory/'sdk-build/android-16'
    for name in ['aapt2','zipalign','apksigner','d8']:
        (tools/name).chmod(0o755)
    return tools,directory/'sdk-platform/android-36/android.jar',directory/'ecj.jar'


def signing_environment():
    signing=ROOT/'.signing'
    signing.mkdir(exist_ok=True)
    properties=signing/'key.properties'
    store=signing/'elemental-swarm-mobile.p12'
    if not properties.exists():
        if store.exists():raise RuntimeError('Signing key exists but key.properties is missing.')
        password=secrets.token_urlsafe(32)
        properties.write_text('[signing]\npassword='+password+'\nalias=elemental-swarm-mobile\n')
        properties.chmod(0o600)
    config=configparser.ConfigParser()
    config.read(properties)
    environment=os.environ.copy()
    environment['SWARM_SIGNING_PASSWORD']=config['signing']['password']
    alias=config['signing']['alias']
    if not store.exists():
        run(['keytool','-genkeypair','-keystore',store,'-storetype','PKCS12',
             '-storepass:env','SWARM_SIGNING_PASSWORD','-keypass:env','SWARM_SIGNING_PASSWORD',
             '-alias',alias,'-keyalg','RSA','-keysize','3072','-validity','10000',
             '-dname','CN=Elemental Swarm Local Build, OU=Personal Android Build, O=Elemental Swarm, C=JP'],environment)
        store.chmod(0o600)
    return store,alias,environment


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--tools-dir',type=Path,default=ROOT/'.toolchain')
    parser.add_argument('--output',type=Path,default=ROOT/'dist'/ARTIFACT)
    args=parser.parse_args()
    if platform.system()!='Linux' or platform.machine() not in ['x86_64','amd64']:
        raise SystemExit('Use Linux x86_64 (or WSL2) with Java 17+ and Python 3.9+.')
    for name in ['java','keytool']:
        if not shutil.which(name):raise SystemExit('Required command: '+name)
    tools,android,compiler=prepare_tools(args.tools_dir.resolve())
    build=ROOT/'build'
    if build.exists():shutil.rmtree(build)
    build.mkdir()
    classes=build/'classes';classes.mkdir()
    dex=build/'dex';dex.mkdir()
    main_dir=ROOT/'app/src/main'
    resources=build/'resources.zip'
    run([tools/'aapt2','compile','--dir',main_dir/'res','-o',resources])
    unsigned=build/'unsigned.apk'
    run([tools/'aapt2','link','-I',android,'--manifest',main_dir/'AndroidManifest.xml',
         '--min-sdk-version','29','--target-sdk-version','36',
         '-A',main_dir/'assets','-o',unsigned,resources])
    sources=sorted((main_dir/'java').rglob('*.java'))
    run(['java','-jar',compiler,'-source','1.8','-target','1.8','-encoding','UTF-8',
         '-bootclasspath',str(android)+os.pathsep+str(tools/'core-lambda-stubs.jar'),
         '-warn:-deprecation','-d',classes,*sources])
    run(['java','-cp',tools/'lib/d8.jar','com.android.tools.r8.D8','--release',
         '--min-api','29','--lib',android,'--output',dex,*sorted(classes.rglob('*.class'))])
    with zipfile.ZipFile(unsigned,'a',compression=zipfile.ZIP_DEFLATED) as apk:
        for entry in sorted(dex.glob('*.dex')):apk.write(entry,entry.name)
    aligned=build/'aligned.apk'
    run([tools/'zipalign','-P','16','-f','4',unsigned,aligned])
    store,alias,environment=signing_environment()
    output=args.output.resolve();output.parent.mkdir(parents=True,exist_ok=True)
    run(['java','-jar',tools/'lib/apksigner.jar','sign','--ks',store,
         '--ks-key-alias',alias,'--ks-pass','env:SWARM_SIGNING_PASSWORD',
         '--key-pass','env:SWARM_SIGNING_PASSWORD','--min-sdk-version','29',
         '--v1-signing-enabled','false','--v2-signing-enabled','true',
         '--v3-signing-enabled','true','--v4-signing-enabled','false','--out',output,aligned],environment)
    run([tools/'zipalign','-c','-P','16','4',output])
    run(['java','-jar',tools/'lib/apksigner.jar','verify','--verbose','--print-certs',output])
    print('APK:',output)
    print('Bytes:',output.stat().st_size)
    print('SHA256:',hashlib.sha256(output.read_bytes()).hexdigest())


if __name__=='__main__':main()
