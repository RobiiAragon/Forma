#include <fstream>
#include <iostream>
#include <string>
#include "mve/mesh_io_ply.h"
#include "mve/mesh_info.h"
#include "tex/texturing.h"
int main(int argc,char**argv) {
 if(argc!=3){std::cerr<<"usage: verify_mve_face_order mesh.ply new-report.json\n";return 2;}
 std::ifstream occupied(argv[2]);if(occupied.good()){std::cerr<<"report exists\n";return 2;}
 auto mesh=mve::geom::load_ply_mesh(argv[1]);auto faces=mesh->get_faces();auto vertices=mesh->get_vertices();
 mve::MeshInfo info(mesh);tex::prepare_mesh(&info,mesh);
 bool faceExact=faces==mesh->get_faces(),vertexExact=vertices.size()==mesh->get_vertices().size();
 if(vertexExact)for(std::size_t i=0;i<vertices.size();++i)for(int c=0;c<3;++c)if(vertices[i][c]!=mesh->get_vertices()[i][c])vertexExact=false;
 std::ofstream out(argv[2]);out<<"{\"schemaVersion\":1,\"inputFaceCount\":"<<faces.size()/3<<",\"outputFaceCount\":"<<mesh->get_faces().size()/3<<",\"removedFaces\":"<<(faces.size()-mesh->get_faces().size())/3<<",\"faceIndexOrderExact\":"<<(faceExact?"true":"false")<<",\"worldVerticesExact\":"<<(vertexExact?"true":"false")<<",\"vertexCount\":"<<vertices.size()<<",\"calledProductionPrepareMesh\":true,\"GPUUsed\":false}\n";out.close();
 if(!faceExact||!vertexExact){std::cerr<<"prepare_mesh changed source order or coordinates\n";return 1;}
 std::cout<<"PASS actual MVE prepare_mesh: all face indices/order and vertices exact, "<<faces.size()/3<<" faces\n";
}
