#!/usr/bin/env python3
"""Create an unsigned, capture/debug APK variant from a compiled APK.

This is intentionally an offline ZIP/XML patcher. It replaces the APK's compiled
network-security resource with a binary XML containing system and user trust
anchors, while retaining cleartext support already present in this APK. It strips
old signing files because any APK content change invalidates the original
signature. The output must be aligned and signed with the owner's debug/test key
before installation. Do not ship the result as a production build.
"""
from __future__ import annotations
import argparse, io, struct, zipfile
from pathlib import Path

NO=0xFFFFFFFF
TYPE_STRING=0x03
TYPE_BOOLEAN=0x12

def u32(x): return struct.pack('<I', x & 0xffffffff)
def u16(x): return struct.pack('<H', x & 0xffff)

def string_pool(strings):
    # UTF-8 string pool. Offsets point to each string's encoded payload.
    payload=bytearray(); offsets=[]
    for s in strings:
        b=s.encode('utf-8'); offsets.append(len(payload))
        if len(b)>=0x80 or len(s)>=0x80:
            raise ValueError('short-string encoder only supports strings below 128 bytes')
        payload += bytes([len(s),len(b)]) + b + b'\0'
    while len(payload)%4: payload += b'\0'
    hsize=28; start=hsize+4*len(strings); size=start+len(payload)
    out=bytearray(struct.pack('<HHI',1,hsize,size))
    out += u32(len(strings))+u32(0)+u32(0x100)+u32(start)+u32(0)
    for o in offsets: out += u32(o)
    out += payload
    return bytes(out)

def start_tag(line,name_idx,attrs=()):
    # ResXMLTree_startElement: header plus five u32/u16 fields.
    attr_start=20 if attrs else 20
    attr_size=20
    size=36+20*len(attrs)
    out=bytearray(struct.pack('<HHI',0x0102,16,size))
    out += u32(line)+u32(NO)+u32(NO)+u32(name_idx)
    out += u16(attr_start)+u16(attr_size)+u16(len(attrs))+u16(0)+u16(0)+u16(0)
    for a in attrs:
        name,raw,kind,data=a
        out += u32(NO)+u32(name)+u32(raw)+u16(8)+b'\0'+bytes([kind])+u32(data)
    return bytes(out)

def end_tag(line,name_idx):
    return struct.pack('<HHI',0x0103,16,24)+u32(line)+u32(NO)+u32(NO)+u32(name_idx)

def compiled_capture_xml():
    strings=['network-security-config','base-config','cleartextTrafficPermitted','trust-anchors','certificates','src','system','user']
    s={x:i for i,x in enumerate(strings)}
    chunks=[string_pool(strings)]
    chunks.append(struct.pack('<HHI',0x0100,8,8)+u32(0)+u32(0)) if False else None
    chunks += [start_tag(2,s['network-security-config']),
               start_tag(3,s['base-config'],[(s['cleartextTrafficPermitted'],NO,TYPE_BOOLEAN,1)]),
               start_tag(4,s['trust-anchors']),
               start_tag(5,s['certificates'],[(s['src'],s['system'],TYPE_STRING,s['system'])]),
               end_tag(5,s['certificates']),
               start_tag(6,s['certificates'],[(s['src'],s['user'],TYPE_STRING,s['user'])]),
               end_tag(6,s['certificates']),
               end_tag(4,s['trust-anchors']),
               end_tag(3,s['base-config']),
               end_tag(2,s['network-security-config'])]
    total=8+sum(map(len,chunks))
    return struct.pack('<HHI',3,8,total)+b''.join(chunks)

def patch(apk_in:Path, apk_out:Path):
    replacement=compiled_capture_xml()
    found=False
    with zipfile.ZipFile(apk_in,'r') as zin, zipfile.ZipFile(apk_out,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as zout:
        for info in zin.infolist():
            # Remove v1 signature records. The central-directory/APK signing block
            # is not copied by zipfile; output is intentionally unsigned.
            if info.filename in {'res/8G.xml','META-INF/MANIFEST.MF','META-INF/CERT.SF','META-INF/CERT.RSA'}:
                if info.filename=='res/8G.xml':
                    zout.writestr('res/8G.xml',replacement); found=True
                continue
            zout.writestr(info,zin.read(info))
    if not found: raise RuntimeError('res/8G.xml was not present')
    return len(replacement)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('apk',type=Path); ap.add_argument('output',type=Path); a=ap.parse_args()
    n=patch(a.apk,a.output); print(f'wrote {a.output} with {n} byte capture XML; output is UNSIGNED and DEBUG/CAPTURE ONLY')
if __name__=='__main__': main()
