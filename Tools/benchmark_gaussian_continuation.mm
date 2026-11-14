// Isolated native full-resolution continuation. Never writes to a source scan,
// original checkpoint, app library, Vendor source or iPhone.
#include "msplat_c_api.h"
#include "loaders.hpp"
#include "ssim.hpp"
#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>
namespace fs = std::filesystem;
static volatile sig_atomic_t interrupted = 0;
static void onSignal(int) { interrupted = 1; }
static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static NSString* ns(const std::string& text) { return [NSString stringWithUTF8String:text.c_str()]; }
static void require(bool condition,const std::string& message) { if(!condition)throw std::runtime_error(message); }
static void json(const fs::path& file,id value) {
    NSError* error=nil;
    NSData* data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    require(data && [data writeToFile:ns(file.string()) options:NSDataWritingAtomic error:&error],"JSON write failed: "+file.string());
}
static std::string sha256(const fs::path& file) {
    std::ifstream stream(file,std::ios::binary);require(bool(stream),"Missing source: "+file.string());
    CC_SHA256_CTX context;CC_SHA256_Init(&context);std::vector<char> block(1024*1024);
    while(stream){stream.read(block.data(),block.size());auto count=stream.gcount();if(count>0)CC_SHA256_Update(&context,block.data(),CC_LONG(count));}
    require(stream.eof(),"Source read failed: "+file.string());unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);
    static const char* hex="0123456789abcdef";std::string value;for(auto byte:digest){value+=hex[byte>>4];value+=hex[byte&15];}return value;
}
static NSDictionary* memory() {
    task_vm_info_data_t info{};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    kern_return_t result=task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count);
    struct rusage usage{};getrusage(RUSAGE_SELF,&usage);
    return @{@"physicalFootprintMiB":@(result==KERN_SUCCESS?double(info.phys_footprint)/(1024*1024):-1),
        @"residentMiB":@(result==KERN_SUCCESS?double(info.resident_size)/(1024*1024):-1),
        @"lifetimePeakResidentMiB":@(double(usage.ru_maxrss)/(1024*1024))};
}
static NSDictionary* checkCheckpoint(const fs::path& path) {
    std::ifstream file(path,std::ios::binary);require(bool(file),"Missing checkpoint");
    uint32_t header[6];float rates[8];file.read(reinterpret_cast<char*>(header),sizeof(header));file.read(reinterpret_cast<char*>(rates),sizeof(rates));
    require(file && header[0]==1280332621 && header[1]==1,"Checkpoint header invalid");
    for(float value:rates)require(std::isfinite(value),"Checkpoint LR nonfinite");
    static const char* names[]={"means","scales","quats","featuresDc","featuresRest","opacities",
        "adamM.means","adamM.scales","adamM.quats","adamM.featuresDc","adamM.featuresRest","adamM.opacities",
        "adamV.means","adamV.scales","adamV.quats","adamV.featuresDc","adamV.featuresRest","adamV.opacities"};
    NSMutableArray* tensors=[NSMutableArray array];std::vector<float> block(256*1024);
    for(int tensor=0;tensor<18;tensor++) {
        uint32_t rank;file.read(reinterpret_cast<char*>(&rank),4);require(file&&rank>0&&rank<=4,"Checkpoint rank invalid");
        uint64_t elements=1;NSMutableArray* shape=[NSMutableArray array];
        for(uint32_t axis=0;axis<rank;axis++){int64_t size;file.read(reinterpret_cast<char*>(&size),8);require(file&&size>0&&uint64_t(size)<=UINT64_MAX/elements,"Checkpoint shape invalid");elements*=size;[shape addObject:@(size)];}
        uint64_t bytes;file.read(reinterpret_cast<char*>(&bytes),8);require(file&&elements<=UINT64_MAX/4&&bytes==elements*4,"Checkpoint length invalid");
        double minimum=INFINITY,maximum=-INFINITY;uint64_t nonfinite=0,negative=0;
        for(uint64_t offset=0;offset<elements;){size_t n=std::min<uint64_t>(block.size(),elements-offset);file.read(reinterpret_cast<char*>(block.data()),n*4);require(bool(file),"Checkpoint truncated");
            for(size_t i=0;i<n;i++){float v=block[i];if(!std::isfinite(v))nonfinite++;else{minimum=std::min(minimum,double(v));maximum=std::max(maximum,double(v));if(v<0)negative++;}}offset+=n;}
        require(nonfinite==0,std::string("Nonfinite checkpoint tensor ")+names[tensor]);
        require(tensor<12||negative==0,std::string("Negative Adam second moment ")+names[tensor]);
        [tensors addObject:@{@"tensor":ns(names[tensor]),@"shape":shape,@"elements":@(elements),@"nonfinite":@(nonfinite),@"negative":@(negative),@"minimum":@(minimum),@"maximum":@(maximum)}];
    }
    require(file.peek()==EOF,"Unexpected checkpoint tail");
    return @{@"step":@(header[2]),@"splats":@(header[3]),@"all18TensorsFinite":@YES,@"allAdamSecondMomentsNonnegative":@YES,
        @"meansLearningRateStored":@(rates[0]),@"meansLearningRateInitial":@(rates[6]),@"meansLearningRateFinal":@(rates[7]),@"tensors":tensors};
}
static void png(const fs::path& file,const MsplatPixelBuffer& image) {
    std::vector<uint8_t> pixels(size_t(image.width)*image.height*4);
    for(size_t i=0;i<size_t(image.width)*image.height;i++){for(int c=0;c<3;c++)pixels[i*4+c]=uint8_t(std::clamp(image.data[i*3+c]*255.f,0.f,255.f));pixels[i*4+3]=255;}
    CFDataRef data=CFDataCreate(nullptr,pixels.data(),pixels.size());CGDataProviderRef provider=CGDataProviderCreateWithCFData(data);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef cg=CGImageCreate(image.width,image.height,8,32,image.width*4,space,kCGImageAlphaLast,provider,nullptr,false,kCGRenderingIntentDefault);
    NSURL* url=[NSURL fileURLWithPath:ns(file.string())];CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,nullptr);
    require(destination&&cg,"PNG allocation failed");CGImageDestinationAddImage(destination,cg,nullptr);bool ok=CGImageDestinationFinalize(destination);
    CFRelease(destination);CFRelease(cg);CFRelease(space);CFRelease(provider);CFRelease(data);require(ok,"PNG encoding failed");
}
struct Target { int nativeIndex;int chronologicalIndex;std::string id;fs::path source; };
static NSDictionary* evaluate(MsplatTrainer trainer,const Target& target,const fs::path& directory) {
    double start=now();MsplatPixelBuffer rendered=msplat_trainer_render(trainer,target.nativeIndex,false);msplat_sync();double renderedAt=now();
    require(rendered.data&&rendered.width>0&&rendered.height>0,"Empty native render");
    Image source=imreadRGB(target.source.string());require(source.width==rendered.width&&source.height==rendered.height,"Source/raster dimensions differ");
    size_t count=size_t(rendered.width)*rendered.height*3;double absolute=0,square=0;size_t nonfinite=0;
    for(size_t i=0;i<count;i++){if(!std::isfinite(rendered.data[i])){nonfinite++;continue;}double d=double(rendered.data[i])-source.data[i];absolute+=std::abs(d);square+=d*d;}
    require(nonfinite==0,"Native render nonfinite");absolute/=count;square/=count;
    MTensor cpuRender({rendered.height,rendered.width,3},DType::Float32),cpuSource({rendered.height,rendered.width,3},DType::Float32);
    memcpy(cpuRender.data_ptr(),rendered.data,count*4);memcpy(cpuSource.data_ptr(),source.data.data(),count*4);
    double beforeSSIM=now();float ssim=ssim_eval(cpuRender,cpuSource,11,1.5f);double afterSSIM=now();require(std::isfinite(ssim),"SSIM nonfinite");
    std::string filename="view-"+std::to_string(target.chronologicalIndex)+".png";png(directory/filename,rendered);free(rendered.data);
    return @{@"chronologicalIndex":@(target.chronologicalIndex),@"nativeCameraIndex":@(target.nativeIndex),@"frameID":ns(target.id),@"sourceRGB":ns(target.source.string()),
        @"width":@(source.width),@"height":@(source.height),@"L1":@(absolute),@"RMSE":@(sqrt(square)),@"PSNRdB":@(-10*log10(square)),@"SSIM":@(ssim),
        @"SSIMMethod":@"Existing native CPU ssim_eval; full native raster, Gaussian11 sigma1.5, replicate borders; RGB channel mean",
        @"renderSeconds":@(renderedAt-start),@"SSIMCPUSeconds":@(afterSSIM-beforeSSIM),@"evaluationSeconds":@(now()-start),@"renderPNG":ns(filename),@"memory":memory()};
}
int main(int argc,char**argv) {@autoreleasepool {
    MsplatDataset dataset=nullptr;MsplatTrainer trainer=nullptr;fs::path output;
    try {
        require(argc==5,"Usage: DATASET ORIGINAL3000_CHECKPOINT MATCHING_MAC_METALLIB NEW_OUTPUT");
        fs::path source=fs::canonical(argv[1]),original=fs::canonical(argv[2]),metal=fs::canonical(argv[3]);output=fs::absolute(argv[4]);
        require(!fs::exists(output),"Output must be new");fs::create_directories(output);
        signal(SIGINT,onSignal);signal(SIGTERM,onSignal);
        InputData input=inputDataFromX(source.string());std::set<fs::path> files={original,source/"dataset.json",source/"images.txt",source/"cameras.txt",source/"points3D.txt"};
        for(auto& camera:input.cameras)files.insert(fs::canonical(camera.filePath));std::map<std::string,std::string> hashes;NSMutableDictionary* before=[NSMutableDictionary dictionary];
        for(auto& path:files){auto value=sha256(path);hashes[path.string()]=value;before[ns(path.string())]=ns(value);}json(output/"input-sha256-before.json",before);
        auto sourceState=checkCheckpoint(original);require([sourceState[@"step"] intValue]==3000,"Experiment requires the preserved3000-step checkpoint");json(output/"source-checkpoint-validation.json",sourceState);
        fs::copy_file(original,output/"source-3000.ckpt");require(sha256(output/"source-3000.ckpt")==hashes[original.string()],"Owned checkpoint copy mismatch");
        NSData* manifestBytes=[NSData dataWithContentsOfFile:ns((source/"dataset.json").string())];NSDictionary* manifest=[NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:nil];
        NSArray* frames=[manifest[@"frames"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b){return [a[@"timestamp"] compare:b[@"timestamp"]];}];
        require(frames.count>=3,"Three distinct evaluation observations required");std::vector<Target> targets;
        for(int index:{0,int(frames.count/2),int(frames.count-1)}){NSDictionary* frame=frames[index];fs::path rgb=source/std::string([frame[@"rgbFile"] UTF8String]);int camera=-1;
            for(size_t i=0;i<input.cameras.size();i++)if(fs::path(input.cameras[i].filePath).filename()==rgb.filename()){camera=int(i);break;}
            require(camera>=0,"Evaluation observation has no native camera");targets.push_back({camera,index,std::string([frame[@"id"] UTF8String]),rgb});}
        json(output/"configuration.json",@{@"requestedScheduleIterations":@30000,@"stopDensifyAt":@30000,@"downscaleFactor":@1,@"numDownscales":@0,@"keepCrs":@YES,
            @"evaluationSteps":@[@3000,@3500,@5000],@"scope":@"Isolated continuation and observed-training-view quality; not held out or Polycam comparison",
            @"policyChange":@"Horizon3000 to30000 changes means LR schedule and continues native refinement; not iterations alone",
            @"sourcesRetained":@YES,@"nativeSourceSHA256":ns(hashes[original.string()]),@"metalSHA256":ns(sha256(metal)),@"runtime":@"macOS native Metal; no Comfy/network"});
        msplat_set_metallib_path(metal.c_str());dataset=msplat_dataset_create(source.c_str(),1,false,8);
        auto config=msplat_default_config();config.iterations=30000;config.stopDensifyAt=30000;config.keepCrs=true;config.downscaleFactor=1;config.numDownscales=0;
        trainer=msplat_trainer_create(dataset,config);int step=msplat_trainer_load_checkpoint(trainer,(output/"source-3000.ckpt").c_str());
        NSMutableArray* stages=[NSMutableArray array];double trainingSeconds=0;double start=now();
        for(int target:{3000,3500,5000}) {
            double segment=now();while(step<target&&!interrupted){@autoreleasepool{auto stats=msplat_trainer_step(trainer);msplat_sync();step=stats.iteration;
                if(step%25==0){json(output/"progress.json",@{@"step":@(step),@"stageTarget":@(target),@"splats":@(stats.splatCount),@"elapsedSeconds":@(now()-start),@"memory":memory()});
                    std::cout<<"PROGRESS step="<<step<<" count="<<stats.splatCount<<" ms="<<stats.msPerStep<<std::endl;}}}
            double segmentSeconds=now()-segment;trainingSeconds+=segmentSeconds;fs::path directory=output/("step-"+std::to_string(step));fs::create_directories(directory);
            msplat_trainer_save_checkpoint(trainer,(directory/"entrenamiento.ckpt").c_str());auto state=checkCheckpoint(directory/"entrenamiento.ckpt");json(directory/"checkpoint-validation.json",state);
            msplat_trainer_export_ply(trainer,(directory/"gaussianas.ply").c_str());msplat_trainer_export_splat(trainer,(directory/"gaussianas.splat").c_str());
            NSMutableArray* metrics=[NSMutableArray array];if(!interrupted)for(auto& view:targets){@autoreleasepool{[metrics addObject:evaluate(trainer,view,directory)];}}
            NSDictionary* stage=@{@"step":@(step),@"splats":@(msplat_trainer_splat_count(trainer)),@"trainingSegmentSeconds":@(segmentSeconds),@"trainingSecondsCumulative":@(trainingSeconds),
                @"allTensorsFinite":@YES,@"allAdamVNonnegative":@YES,@"metrics":metrics,@"memory":memory(),@"checkpointSHA256":ns(sha256(directory/"entrenamiento.ckpt"))};
            json(directory/"metrics.json",stage);[stages addObject:stage];json(output/"stages.json",stages);if(interrupted)break;
        }
        NSMutableDictionary* after=[NSMutableDictionary dictionary];for(auto& value:hashes){auto actual=sha256(value.first);after[ns(value.first)]=ns(actual);require(actual==value.second,"Original training input changed: "+value.first);}json(output/"input-sha256-after.json",after);
        json(output/"summary.json",@{@"status":interrupted?@"interrupted-checkpoint-preserved":@"completed",@"stages":stages,@"sourceFileCount":@(hashes.size()),@"sourceSHA256Unchanged":@YES,
            @"trainingSeconds":@(trainingSeconds),@"totalSecondsIncludingEvaluation":@(now()-start),@"memory":memory(),@"modelResolutionReduced":@NO,@"populationTruncated":@NO,@"heldOutEvaluation":@NO});
        msplat_trainer_destroy(trainer);msplat_dataset_destroy(dataset);msplat_cleanup();return interrupted?130:0;
    }catch(const std::exception& error){std::cerr<<error.what()<<std::endl;if(!output.empty()&&fs::exists(output))json(output/"failure.json",@{@"error":ns(error.what()),@"memory":memory()});
        if(trainer)msplat_trainer_destroy(trainer);if(dataset)msplat_dataset_destroy(dataset);msplat_cleanup();return 1;}
}}
