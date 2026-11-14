#include <metal_stdlib>
using namespace metal;

struct FormaGaussian {
    float4 positionOpacity;
    float4 scale;
    float4 rotation;
    float4 color;
};
struct FormaGaussianCamera {
    float4x4 view;
    float4x4 projection;
    float4 viewport; // width,height,fx,fy
    float4 eyeAndDegree;
};
struct FormaGaussianRaster {
    float4 position [[position]];
    float2 gaussianCoordinate;
    float4 color;
};

float3x3 formaQuaternion(float4 q) {
    float x=q.x, y=q.y, z=q.z, w=q.w;
    return float3x3(float3(1-2*(y*y+z*z),2*(x*y+z*w),2*(x*z-y*w)),
                    float3(2*(x*y-z*w),1-2*(x*x+z*z),2*(y*z+x*w)),
                    float3(2*(x*z+y*w),2*(y*z-x*w),1-2*(x*x+y*y)));
}

vertex FormaGaussianRaster formaGaussianVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
    const device FormaGaussian *points [[buffer(0)]], const device uint *order [[buffer(1)]],
    constant FormaGaussianCamera &camera [[buffer(2)]], const device float4 *allSH [[buffer(3)]]) {
    uint pointID=order[instanceID];
    FormaGaussian g=points[pointID];
    float4 p=camera.view*float4(g.positionOpacity.xyz,1);
    FormaGaussianRaster result;
    result.color=float4(g.color.rgb,g.positionOpacity.w);
    int degree=int(camera.eyeAndDegree.w);
    if (degree>=0) {
        const device float4 *sh=allSH+pointID*16;
        float3 d=normalize(g.positionOpacity.xyz-camera.eyeAndDegree.xyz);
        float x=d.x,y=d.y,z=d.z,xx=x*x,yy=y*y,zz=z*z,xy=x*y,yz=y*z,xz=x*z;
        float3 rgb=0.28209479177387814*sh[0].xyz;
        if (degree>=1) rgb += -0.4886025119029199*y*sh[1].xyz+0.4886025119029199*z*sh[2].xyz-0.4886025119029199*x*sh[3].xyz;
        if (degree>=2) rgb += 1.0925484305920792*xy*sh[4].xyz-1.0925484305920792*yz*sh[5].xyz+0.31539156525252005*(2*zz-xx-yy)*sh[6].xyz-1.0925484305920792*xz*sh[7].xyz+0.5462742152960396*(xx-yy)*sh[8].xyz;
        if (degree>=3) rgb += -0.5900435899266435*y*(3*xx-yy)*sh[9].xyz+2.890611442640554*xy*z*sh[10].xyz-0.4570457994644658*y*(4*zz-xx-yy)*sh[11].xyz+0.3731763325901154*z*(2*zz-3*xx-3*yy)*sh[12].xyz-0.4570457994644658*x*(4*zz-xx-yy)*sh[13].xyz+1.445305721320277*z*(xx-yy)*sh[14].xyz-0.5900435899266435*x*(xx-3*yy)*sh[15].xyz;
        result.color.rgb=max(rgb+0.5,0.0);
    }
    result.gaussianCoordinate=float2(0);
    if (p.z>=-0.001 || !all(isfinite(p))) {
        result.position=float4(2,2,2,1);
        result.color.a=0;
        return result;
    }
    float3x3 R=formaQuaternion(g.rotation);
    float3x3 V=float3x3(camera.view[0].xyz,camera.view[1].xyz,camera.view[2].xyz);
    float3x3 T=V*R*float3x3(float3(g.scale.x,0,0),float3(0,g.scale.y,0),float3(0,0,g.scale.z));
    float3x3 covariance=T*transpose(T);
    float z=-p.z;
    float fx=camera.projection[0][0]*camera.viewport.x*0.5;
    float fy=camera.projection[1][1]*camera.viewport.y*0.5;
    float skewX=camera.projection[1][0]*camera.viewport.x*0.5;
    float skewY=camera.projection[0][1]*camera.viewport.y*0.5;
    // Match the training rasterizer's EWA linearization outside the frustum.
    // Unbounded offscreen x/z can otherwise create an ellipse covering the
    // whole image. Keep the actual center, scale, SH and every input point.
    float limitX=1.3f*camera.viewport.x/(2*fx);
    float limitY=1.3f*camera.viewport.y/(2*fy);
    float covX=z*clamp(p.x/z,-limitX,limitX);
    float covY=z*clamp(p.y/z,-limitY,limitY);
    float3 jx=float3(fx/z,skewX/z,(fx*covX+skewX*covY)/(z*z));
    float3 jy=float3(skewY/z,fy/z,(skewY*covX+fy*covY)/(z*z));
    float a=dot(jx,covariance*jx)+0.3;
    float b=dot(jx,covariance*jy);
    float c=dot(jy,covariance*jy)+0.3;
    if (!isfinite(a) || !isfinite(b) || !isfinite(c)) {
        result.position=float4(2,2,2,1);
        result.color.a=0;
        return result;
    }
    float midpoint=0.5*(a+c);
    float spread=sqrt(max(0.0,0.25*(a-c)*(a-c)+b*b));
    float lambda1=max(0.00001,midpoint+spread), lambda2=max(0.00001,midpoint-spread);
    float theta=0.5*atan2(2*b,a-c);
    float2 axis1=float2(cos(theta),sin(theta))*sqrt(lambda1);
    float2 axis2=float2(-sin(theta),cos(theta))*sqrt(lambda2);
    const float2 corners[6]={float2(-3,-3),float2(3,-3),float2(-3,3),float2(-3,3),float2(3,-3),float2(3,3)};
    float2 local=corners[vertexID];
    float2 pixelOffset=axis1*local.x+axis2*local.y;
    float4 clip=camera.projection*p;
    clip.xy += 2*pixelOffset/camera.viewport.xy*clip.w;
    if (!all(isfinite(clip)) || !all(isfinite(result.color))) {
        result.position=float4(2,2,2,1);
        result.color.a=0;
        return result;
    }
    result.position=clip;
    result.gaussianCoordinate=local;
    return result;
}

fragment float4 formaGaussianFragment(FormaGaussianRaster in [[stage_in]]) {
    float power=dot(in.gaussianCoordinate,in.gaussianCoordinate);
    float alpha=in.color.a*exp(-0.5*power);
    return float4(in.color.rgb*alpha,alpha);
}
