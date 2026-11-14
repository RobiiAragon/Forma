// Research-only CPU visibility: same two-sided triangle/BVH semantics as the
// photographic baker. This helper never writes mesh or capture data.
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
struct V { double x[3]; double &operator[](int i) { return x[i]; } double operator[](int i) const { return x[i]; } };
V sub(V a, V b) { return {{a[0]-b[0],a[1]-b[1],a[2]-b[2]}}; }
V cross(V a,V b) { return {{a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]}}; }
double dot(V a,V b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
struct Triangle { V a,b,c,center; };
struct Node { V lo,hi; std::size_t start=0,count=0; int left=-1,right=-1; };
struct BVH {
    std::vector<Triangle> triangles;
    std::vector<std::size_t> order;
    std::vector<Node> nodes;
    BVH(const double *v,std::size_t nv,const std::uint32_t *t,std::size_t nt) {
        if(!nv || !nt) throw std::runtime_error("Empty visibility mesh");
        for(std::size_t i=0;i<nv*3;i++) if(!std::isfinite(v[i])) throw std::runtime_error("Nonfinite vertex");
        triangles.reserve(nt);
        for(std::size_t i=0;i<nt;i++) {
            V p[3];
            for(int j=0;j<3;j++) { auto n=t[i*3+j]; if(n>=nv) throw std::runtime_error("Invalid triangle index"); p[j]={{v[n*3],v[n*3+1],v[n*3+2]}}; }
            V center={{(p[0][0]+p[1][0]+p[2][0])/3,(p[0][1]+p[1][1]+p[2][1])/3,(p[0][2]+p[1][2]+p[2][2])/3}};
            triangles.push_back({p[0],p[1],p[2],center});
        }
        order.resize(nt); std::iota(order.begin(),order.end(),0); nodes.reserve(nt/3+1); build(0,nt);
    }
    int build(std::size_t start,std::size_t end) {
        double inf=std::numeric_limits<double>::infinity();
        V lo={{inf,inf,inf}},hi={{-inf,-inf,-inf}},cl=lo,ch=hi;
        for(auto i=start;i<end;i++) { const auto &t=triangles[order[i]]; for(int a=0;a<3;a++) {
            lo[a]=std::min({lo[a],t.a[a],t.b[a],t.c[a]}); hi[a]=std::max({hi[a],t.a[a],t.b[a],t.c[a]});
            cl[a]=std::min(cl[a],t.center[a]); ch[a]=std::max(ch[a],t.center[a]);
        }}
        int index=int(nodes.size()); nodes.push_back({lo,hi,start,end-start,-1,-1});
        if(end-start<=8) return index;
        V extent=sub(ch,cl); int axis=extent[0]>=extent[1]&&extent[0]>=extent[2]?0:extent[1]>=extent[2]?1:2;
        auto middle=(start+end)/2;
        std::nth_element(order.begin()+start,order.begin()+middle,order.begin()+end,[&](auto a,auto b) {
            return triangles[a].center[axis]==triangles[b].center[axis]?a<b:triangles[a].center[axis]<triangles[b].center[axis];
        });
        int left=build(start,middle),right=build(middle,end); nodes[index].left=left; nodes[index].right=right; nodes[index].count=0; return index;
    }
    bool triangle(const Triangle &t,V origin,V direction,double maximum) const {
        V e1=sub(t.b,t.a),e2=sub(t.c,t.a),p=cross(direction,e2); double determinant=dot(e1,p);
        if(std::abs(determinant)<=1e-8) return false;
        double inverse=1/determinant; V offset=sub(origin,t.a); double u=dot(offset,p)*inverse;
        if(u< -1e-5 || u>1.00001) return false;
        V q=cross(offset,e1); double v=dot(direction,q)*inverse;
        if(v< -1e-5 || u+v>1.00001) return false;
        double distance=dot(e2,q)*inverse;
        return distance>1e-4 && distance<maximum;
    }
    bool intersects(int index,V origin,V direction,double maximum) const {
        const auto &n=nodes[index]; double near=1e-4,far=maximum;
        for(int a=0;a<3;a++) {
            if(std::abs(direction[a])<1e-7) { if(origin[a]<n.lo[a] || origin[a]>n.hi[a]) return false; }
            else { double x=(n.lo[a]-origin[a])/direction[a],y=(n.hi[a]-origin[a])/direction[a]; near=std::max(near,std::min(x,y)); far=std::min(far,std::max(x,y)); if(far<near) return false; }
        }
        if(n.count) { for(auto i=n.start;i<n.start+n.count;i++) if(triangle(triangles[order[i]],origin,direction,maximum)) return true; return false; }
        return intersects(n.left,origin,direction,maximum)||intersects(n.right,origin,direction,maximum);
    }
    bool occluded(V origin,V point) const {
        V direction=sub(point,origin); double distance=std::sqrt(dot(direction,direction));
        if(!std::isfinite(distance)||distance<=.001) return true;
        for(int i=0;i<3;i++) direction[i]/=distance;
        // Matches baker: exclude the endpoint neighborhood, not a second surface.
        return intersects(0,origin,direction,distance-std::max(.0001,distance*.001));
    }
};
thread_local std::string error;
}
extern "C" {
const char *seed_bvh_error() { return error.c_str(); }
void *seed_bvh_create(const double *vertices,std::size_t vertexCount,const std::uint32_t *triangles,std::size_t faceCount) {
    try { error.clear(); return new BVH(vertices,vertexCount,triangles,faceCount); } catch(const std::exception &e) { error=e.what(); return nullptr; }
}
void seed_bvh_destroy(void *handle) { delete static_cast<BVH*>(handle); }
int seed_bvh_occluded(void *handle,const double *origin,const double *points,std::size_t count,std::uint8_t *out) {
    try { if(!handle) throw std::runtime_error("Missing BVH"); V o={{origin[0],origin[1],origin[2]}}; for(std::size_t i=0;i<count;i++) out[i]=static_cast<BVH*>(handle)->occluded(o,{{points[i*3],points[i*3+1],points[i*3+2]}})?1:0; return 0; }
    catch(const std::exception &e) { error=e.what(); return -1; }
}
}
