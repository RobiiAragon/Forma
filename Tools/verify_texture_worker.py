#!/usr/bin/env python3
"""CPU-only authored-fixture acceptance. Does not read or modify user captures."""
import argparse, hashlib, json, os, shutil, struct, subprocess, tempfile, zlib
from pathlib import Path

def sha(data): return hashlib.sha256(data).hexdigest()
def png(path):
    def chunk(k,d):return struct.pack('>I',len(d))+k+d+struct.pack('>I',zlib.crc32(k+d))
    w=h=64;raw=b''.join(b'\0'+bytes(v for x in range(w) for v in (x*4,y*4,(x+y)*2)) for y in range(h))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
def run(worker,root):
    root.mkdir(parents=True,exist_ok=False);scene=root/'scene';scene.mkdir()
    png(scene/'00000000.png');(scene/'00000000.cam').write_text('0 0 0 1 0 0 0 1 0 0 0 1\n1 0 0 1 0.5078125 0.5078125\n')
    (scene/'00000000.forma-lut').write_text('FORMA_RADIAL_LUT_V1\n64 64 32 32 45.254833995939045 3\n0 0.01 0.02\n')
    vertices=[(-.8,-.8,2),(.8,-.8,2),(.8,.8,2),(-.8,.8,2)];faces=[(0,2,1),(0,3,2)]
    vertexbytes=b''.join(struct.pack('<3f',*v) for v in vertices);indexbytes=b''.join(struct.pack('<3I',*f) for f in faces)
    def mesh(path,ff):
        path.write_bytes(('ply\nformat binary_little_endian 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nelement face '+str(len(ff))+'\nproperty list uchar uint vertex_indices\nend_header\n').encode()+vertexbytes+b''.join(struct.pack('<B3I',3,*f) for f in ff))
    mesh(root/'mesh.ply',faces);snapshot={str(p.relative_to(root)):sha(p.read_bytes()) for p in root.rglob('*') if p.is_file()}
    def call(name,extra=(),which='mesh.ply',success=True):
        output=root/name;output.mkdir();cmd=[str(worker),'--forma_labels_only','--forma_native_lut','--num_threads=1',*extra,str(scene),str(root/which),str(output/'model')]
        result=subprocess.run(cmd,capture_output=True,timeout=60);(output/'worker.log').write_bytes(result.stdout+result.stderr)
        assert (result.returncode==0)==success,(cmd,result.returncode,result.stdout[-2000:],result.stderr)
        return output
    first=call('computed');receipt=json.loads((first/'model_forma_geometry.json').read_text());labels=(first/'model_labeling.vec').read_bytes()
    assert receipt['status']=='complete' and receipt['workerABI']=='FORMA_LABELS_ONLY_V1'
    assert receipt['faceCount']==2 and receipt['vertexCount']==4 and receipt['textureViewCount']==1
    assert receipt['beforeVertexSHA256']==receipt['afterVertexSHA256']==sha(vertexbytes)
    assert receipt['beforeFaceIndexSHA256']==receipt['afterFaceIndexSHA256']==sha(indexbytes)
    assert receipt['inputMeshSHA256']==snapshot['mesh.ply'] and receipt['labelsSHA256']==sha(labels)
    assert receipt['faceIndexOrderExact'] and receipt['worldVerticesExact'] and receipt['removedFaces']==0
    assert len(labels)==16 and struct.unpack('<2Q',labels)==(1,1)
    assert (first/'model_data_costs.spt').stat().st_size>0 and not list(first.glob('*.obj')) and not list(first.glob('*.png')) and not (first/'tmp').exists()
    reused=call('reuse-costs',['-D',str(first/'model_data_costs.spt')]);assert (reused/'model_labeling.vec').read_bytes()==labels
    attached=call('reuse-labels',['-L',str(first/'model_labeling.vec')]);assert (attached/'model_labeling.vec').read_bytes()==labels
    assert json.loads((attached/'model_forma_geometry.json').read_text())['labelsSHA256']==sha(labels)
    mesh(root/'duplicate.ply',[faces[0],faces[0],faces[1]])
    rejected=call('duplicate-rejected',which='duplicate.ply',success=False)
    rejected_receipt=json.loads((rejected/'model_forma_geometry.json').read_text());assert rejected_receipt['status']=='rejected_geometry_changed' and rejected_receipt['removedFaces']==1 and not (rejected/'model_labeling.vec').exists()
    (root/'trailing-labels.vec').write_bytes(labels+b'x');call('trailing-label-rejected',['-L',str(root/'trailing-labels.vec')],success=False)
    call('publication-disabled-rejected',['--no_intermediate_results'],success=False)
    assert all(sha((root/p).read_bytes())==h for p,h in snapshot.items())
    report=dict(status='passed',GPUUsed=False,authoredOnly=True,computedAndCostReuseAndLabelReuse=True,unchangedGeometryReceiptIndependentlyHashed=True,duplicateFaceGeometryChangeRejected=True,trailingLabelBytesRejected=True,disabledPublicationRejected=True,noUVOrAtlasOutput=True,sourceSHA256Unchanged=True)
    (root/'verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--worker',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();run(a.worker.resolve(),a.output.resolve())
