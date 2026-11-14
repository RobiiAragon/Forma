// Local macOS worker. No ComfyUI, cloud service, subscription, or training quota.
// The app may leave the foreground or disconnect; status/control stay on disk.
#import <Foundation/Foundation.h>
#include "forma_gaussian.h"
#include "forma_shader_abi.h"
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <limits>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
namespace {
volatile sig_atomic_t interrupted = 0;
void signalHandler(int value) { interrupted = value; }
std::string utf8(NSString* text) { return text ? std::string(text.UTF8String) : std::string(); }
NSString* ns(const std::string& text) { return [NSString stringWithUTF8String:text.c_str()]; }
double now() { return NSProcessInfo.processInfo.systemUptime; }

NSDictionary* json(NSData* data) {
    NSError* error = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![value isKindOfClass:NSDictionary.class])
        throw std::runtime_error("Se esperaba un objeto JSON válido.");
    return value;
}

std::string text(NSDictionary* object,NSString* key,bool required = true) {
    id value = object[key];
    if (!value && !required) return {};
    if (![value isKindOfClass:NSString.class] || ![value length])
        throw std::runtime_error("Falta un texto válido en " + utf8(key));
    return utf8(value);
}

double number(NSDictionary* object,NSString* key,double fallback) {
    id value = object[key];
    if (!value) return fallback;
    if (![value isKindOfClass:NSNumber.class] || !std::isfinite([value doubleValue]))
        throw std::runtime_error("Falta un número finito en " + utf8(key));
    return [value doubleValue];
}

bool inside(const fs::path& child,const fs::path& parent) {
    auto a=child.begin(), b=parent.begin();
    for (;b!=parent.end();++a,++b) if(a==child.end() || *a!=*b) return false;
    return true;
}

struct Config {
    std::string jobID;
    fs::path dataset, workspace, metallib, resume;
    int32_t iterations = 3000;
    float downscale = 1;
    double checkpointSeconds = 30, progressSeconds = .5;
    bool initiallyPaused = false, resumeOnLaunch = false;

    explicit Config(const fs::path& path) {
        NSData* bytes=[NSData dataWithContentsOfFile:ns(path.string())];
        if(!bytes) throw std::runtime_error("No se pudo leer la configuración del trabajo.");
        NSDictionary* object=json(bytes);
        if(number(object,@"schemaVersion",1)!=1) throw std::runtime_error("Versión de configuración desconocida.");
        jobID=text(object,@"jobID");
        if(![[[NSUUID alloc] initWithUUIDString:ns(jobID)] autorelease]) throw std::runtime_error("jobID debe ser un UUID.");
        dataset=fs::canonical(text(object,@"datasetPath"));
        workspace=fs::weakly_canonical(text(object,@"workspacePath"));
        metallib=fs::canonical(text(object,@"metallibPath"));
        const std::string source=text(object,@"resumePath",false);
        if(!source.empty()) resume=fs::canonical(source);
        const double count=number(object,@"targetIterations",3000);
        const double factor=number(object,@"downscale",1);
        if(count<1 || count>INT32_MAX || std::floor(count)!=count || factor<1 || factor>std::numeric_limits<float>::max())
            throw std::runtime_error("Configuración no representable por el motor: iteraciones enteras positivas y factor de resolución ≥ 1.");
        iterations=static_cast<int32_t>(count); downscale=static_cast<float>(factor);
        checkpointSeconds=number(object,@"checkpointIntervalSeconds",30);
        progressSeconds=number(object,@"progressIntervalSeconds",.5);
        if(checkpointSeconds<0 || progressSeconds<=0) throw std::runtime_error("Intervalos de guardado/progreso inválidos.");
        initiallyPaused=[object[@"initiallyPaused"] boolValue];
        resumeOnLaunch=[object[@"resumeOnLaunch"] boolValue];
        if(!fs::is_directory(dataset) || !fs::is_regular_file(metallib)) throw std::runtime_error("Faltan las fuentes o los shaders Metal.");
        if(inside(workspace,dataset) || inside(dataset,workspace))
            throw std::runtime_error("La carpeta de trabajo debe ser independiente de la carpeta de fuentes.");
    }
};

class Worker {
    enum class Intent { run,pause,exportModel,cancel };
    Config config;
    FormaGaussianHandle engine=nullptr;
    FormaGaussianStats stats{};
    Intent intent=Intent::run;
    int lockFD=-1, controlFD=-1;
    off_t controlOffset=0;
    bool stdinOpen=true, stdoutOpen=true, explicitCheckpoint=false;
    std::string stdinBuffer, phase="preparing", message="Preparando entrenamiento local en Mac";
    std::string lastCommandID, commandState, errorMessage, resultPath;
    fs::path resumeSource, lastCheckpoint;
    int32_t checkpointStep=0;
    double lastProgress=0, lastSaved=now(), started=now();
    id activity=nil;

    fs::path statusPath() const { return config.workspace/"status.json"; }
    fs::path checkpointPath() const { return config.workspace/"entrenamiento.ckpt"; }

    void releaseEngine() {
        if(engine) { forma_gaussian_destroy(engine); engine=nullptr; }
        if(activity) { [NSProcessInfo.processInfo endActivity:activity]; [activity release]; activity=nil; }
    }

    void publish(const std::string& event,bool force=true) {
        if(!force && now()-lastProgress<config.progressSeconds) return;
        lastProgress=now();
        NSMutableDictionary* value=[NSMutableDictionary dictionaryWithDictionary:@{
            @"schemaVersion":@1,@"event":ns(event),@"jobID":ns(config.jobID),@"pid":@(getpid()),
            @"phase":ns(phase),@"message":ns(message),@"iteration":@(stats.iteration),
            @"targetIterations":@(config.iterations),@"splats":@(stats.splats),
            @"progress":@(std::min(1.,double(stats.iteration)/config.iterations)),
            @"millisecondsPerStep":@(stats.milliseconds),@"downscale":@(config.downscale),
            @"datasetPath":ns(config.dataset.string()),@"workspacePath":ns(config.workspace.string()),
            @"updatedAt":@([[NSDate date] timeIntervalSince1970]),@"elapsedSeconds":@(now()-started),
            @"checkpointStep":@(checkpointStep),@"controlOffset":@(controlOffset),
            @"checkpointIntervalSeconds":@(config.checkpointSeconds),@"runtimeABI":@(FORMA_MSPLAT_RUNTIME_ABI),
            @"platform":@"macOS",@"localOnly":@YES,@"continuesWhenAppDisconnects":@YES
        }];
        if(!lastCheckpoint.empty()) value[@"checkpointPath"]=ns(lastCheckpoint.string());
        if(!resultPath.empty()) value[@"resultPath"]=ns(resultPath);
        if(!lastCommandID.empty()) { value[@"commandID"]=ns(lastCommandID); value[@"commandState"]=ns(commandState); }
        if(!errorMessage.empty()) value[@"error"]=ns(errorMessage);
        NSError* error=nil;
        NSData* bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
        if(!bytes || ![bytes writeToFile:ns(statusPath().string()) options:NSDataWritingAtomic error:&error])
            throw std::runtime_error("No se pudo persistir el estado del trabajo: "+utf8(error.localizedDescription));
        if(stdoutOpen) {
            std::string line="FORMA_GAUSSIAN "; line.append(static_cast<const char*>(bytes.bytes),bytes.length); line.push_back('\n');
            size_t written=0;
            while(written<line.size()) {
                const ssize_t count=write(STDOUT_FILENO,line.data()+written,line.size()-written);
                if(count>0) written+=count;
                else if(count<0 && errno==EINTR) continue;
                else { stdoutOpen=false; break; }
            }
        }
    }

    void accept(const std::string& line) {
        if(line.empty()) return;
        try {
            NSData* bytes=[NSData dataWithBytes:line.data() length:line.size()];
            NSDictionary* command=json(bytes);
            const std::string owner=text(command,@"jobID",false);
            if(!owner.empty() && owner!=config.jobID) throw std::runtime_error("El comando pertenece a otro trabajo.");
            const std::string action=text(command,@"command");
            const std::string identifier=text(command,@"commandID",false);
            if(!identifier.empty() && identifier==lastCommandID) return;
            lastCommandID=identifier;
            if(intent==Intent::cancel) throw std::runtime_error("El trabajo ya está cancelándose.");
            if(action=="pause") intent=Intent::pause;
            else if(action=="resume") intent=Intent::run;
            else if(action=="checkpoint") explicitCheckpoint=true;
            else if(action=="export") {
                if(stats.iteration<1) throw std::runtime_error("Todavía no hay pasos entrenados para exportar.");
                intent=Intent::exportModel;
            }
            else if(action=="cancel") intent=Intent::cancel;
            else throw std::runtime_error("Comando desconocido: "+action);
            commandState="accepted"; errorMessage.clear();
            if((action=="resume" && engine && phase=="running") ||
               (action=="pause" && !engine && phase=="paused")) commandState="completed";
            publish("commandAccepted");
        } catch(const std::exception& error) {
            errorMessage=error.what(); commandState="rejected";
            publish("commandRejected");
        }
    }

    void pollControls() {
        if(interrupted) { intent=Intent::cancel; message="Guardando antes de finalizar el proceso"; }
        if(stdinOpen) {
            char bytes[4096];
            while(true) {
                const ssize_t count=read(STDIN_FILENO,bytes,sizeof(bytes));
                if(count>0) stdinBuffer.append(bytes,count);
                else if(count==0) { stdinOpen=false; break; }
                else if(errno==EINTR) continue;
                else if(errno==EAGAIN || errno==EWOULDBLOCK) break;
                else { stdinOpen=false; break; }
            }
            size_t newline;
            while((newline=stdinBuffer.find('\n'))!=std::string::npos) {
                const std::string line=stdinBuffer.substr(0,newline); stdinBuffer.erase(0,newline+1); accept(line);
            }
            if(!stdinOpen && !stdinBuffer.empty()) { accept(stdinBuffer); stdinBuffer.clear(); }
        }
        // Append-only durable control survives closure/relaunch of the app.
        struct stat info{};
        if(fstat(controlFD,&info)!=0) throw std::runtime_error("No se pudo inspeccionar la cola de control.");
        if(controlOffset>info.st_size) throw std::runtime_error("La cola de control se truncó mientras el trabajo estaba activo.");
        while(controlOffset<info.st_size) {
            char bytes[4096];
            const ssize_t count=pread(controlFD,bytes,sizeof(bytes),controlOffset);
            if(count<0 && errno==EINTR) continue;
            if(count<=0) break;
            const std::string block(bytes,count);
            const size_t newline=block.find('\n');
            if(newline==std::string::npos) {
                // A control line may be larger than one read; accumulate it.
                std::string line=block; off_t cursor=controlOffset+count;
                while(cursor<info.st_size && line.find('\n')==std::string::npos) {
                    const ssize_t extra=pread(controlFD,bytes,sizeof(bytes),cursor);
                    if(extra<0 && errno==EINTR) continue;
                    if(extra<=0) break;
                    line.append(bytes,extra); cursor+=extra;
                }
                const size_t end=line.find('\n');
                if(end==std::string::npos) break; // Writer has not completed the line yet.
                controlOffset+=end+1; accept(line.substr(0,end));
            } else { controlOffset+=newline+1; accept(block.substr(0,newline)); }
        }
    }

    void initializeEngine() {
        if(!activity) activity=[[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated|NSActivitySuddenTerminationDisabled|NSActivityAutomaticTerminationDisabled
            reason:@"Reconstrucción Gaussian local de Forma"] retain];
        phase="preparing"; message="Cargando cámaras, modelo y estado del optimizador"; publish("preparing");
        char error[2048]={};
        engine=forma_gaussian_create(config.dataset.c_str(),config.metallib.c_str(),config.iterations,config.downscale,error,sizeof(error));
        if(!engine) throw std::runtime_error(error);
        if(!resumeSource.empty()) {
            int32_t resumed=0;
            if(!forma_gaussian_resume(engine,resumeSource.c_str(),&resumed,error,sizeof(error))) throw std::runtime_error(error);
        }
        if(!forma_gaussian_stats(engine,&stats,error,sizeof(error))) throw std::runtime_error(error);
        if(stats.iteration>config.iterations) throw std::runtime_error("El checkpoint supera el objetivo. Elige un objetivo de iteraciones mayor.");
        phase="running"; message="Optimizando Gaussian 3D con Metal en el Mac"; commandState="completed"; publish("running");
    }

    void saveCheckpoint(const std::string& nextPhase) {
        if(!engine) return;
        phase="checkpointing"; message="Guardando el estado completo sin detener la sesión"; publish("checkpointing");
        char error[2048]={};
        const fs::path checkpoint=checkpointPath();
        if(!forma_gaussian_checkpoint(engine,checkpoint.c_str(),error,sizeof(error))) throw std::runtime_error(error);
        lastCheckpoint=checkpoint; resumeSource=checkpoint; checkpointStep=stats.iteration; lastSaved=now();
        explicitCheckpoint=false; phase=nextPhase;
        commandState=(nextPhase=="pausing" || nextPhase=="cancelling")?"accepted":"completed";
        message="Checkpoint guardado"; publish("checkpointSaved");
    }

    void exportModel() {
        if(!engine) initializeEngine();
        phase="exporting"; message="Exportando PLY, SPLAT y checkpoint completos"; publish("exporting");
        const fs::path staging=config.workspace/('.'+std::string("export-")+utf8(NSUUID.UUID.UUIDString));
        fs::create_directory(staging);
        char error[2048]={};
        if(!forma_gaussian_export(engine,staging.c_str(),error,sizeof(error))) throw std::runtime_error(error);
        NSDictionary* metadata=@{
            @"engine":@"msplat-macos",@"representation":@"trained-3d-gaussian-splatting",@"steps":@(stats.iteration),
            @"requestedIterations":@(config.iterations),@"splats":@(stats.splats),@"downscaleFactor":@(config.downscale),
            @"numDownscales":@0,@"keepCrs":@YES,@"sphericalHarmonicsDegree":@3,@"primaryViewerDegree":@3,@"splatDegree":@0,
            @"localOnly":@YES,@"runtimeABI":@(FORMA_MSPLAT_RUNTIME_ABI),@"jobID":ns(config.jobID)
        };
        NSData* bytes=[NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil];
        if(![bytes writeToFile:ns((staging/"gaussianas.json").string()) options:NSDataWritingAtomic error:nil])
            throw std::runtime_error("No se pudo guardar el informe de la exportación.");
        pollControls();
        if(intent==Intent::cancel) { saveCheckpoint("cancelling"); releaseEngine(); phase="cancelled"; message="Cancelado; checkpoint conservado"; publish("cancelled"); return; }
        const fs::path directory=config.workspace/"exports";
        fs::create_directories(directory);
        const fs::path destination=directory/(std::to_string(stats.iteration)+'-'+utf8(NSUUID.UUID.UUIDString));
        fs::rename(staging,destination);
        resultPath=destination.string(); lastCheckpoint=destination/"entrenamiento.ckpt"; checkpointStep=stats.iteration;
        releaseEngine(); phase="completed"; commandState="completed"; message="Modelo completo y checkpoint guardados"; publish("completed");
    }

public:
    explicit Worker(Config value):config(std::move(value)),resumeSource(config.resume) {
        fs::create_directories(config.workspace);
        lockFD=open((config.workspace/"worker.lock").c_str(),O_RDWR|O_CREAT,0600);
        if(lockFD<0 || flock(lockFD,LOCK_EX|LOCK_NB)!=0) throw std::runtime_error("Otra sesión ya utiliza esta carpeta de trabajo.");
        const std::string pid=std::to_string(getpid())+'\n'; ftruncate(lockFD,0); (void)write(lockFD,pid.data(),pid.size());
        controlFD=open((config.workspace/"control.ndjson").c_str(),O_RDWR|O_CREAT,0600);
        if(controlFD<0) throw std::runtime_error("No se pudo abrir la cola de control persistente.");
        if(fs::exists(statusPath())) {
            NSDictionary* previous=json([NSData dataWithContentsOfFile:ns(statusPath().string())]);
            if(text(previous,@"jobID")!=config.jobID) throw std::runtime_error("La carpeta pertenece a otro trabajo.");
            const std::string previousDataset=text(previous,@"datasetPath",false);
            if(!previousDataset.empty() && fs::canonical(previousDataset)!=config.dataset)
                throw std::runtime_error("El trabajo guardado pertenece a otras fuentes. Usa otra carpeta de trabajo.");
            if(number(previous,@"downscale",config.downscale)!=config.downscale)
                throw std::runtime_error("La resolución guardada no coincide. Usa otro trabajo para cambiarla.");
            controlOffset=static_cast<off_t>(number(previous,@"controlOffset",0));
            const std::string owned=text(previous,@"checkpointPath",false);
            if(!owned.empty() && fs::is_regular_file(owned) && inside(fs::canonical(owned),config.workspace)) {
                lastCheckpoint=owned; checkpointStep=static_cast<int32_t>(number(previous,@"checkpointStep",0));
                if(config.resume.empty()) {
                    resumeSource=lastCheckpoint;
                    stats.iteration=checkpointStep;
                    stats.splats=static_cast<int32_t>(number(previous,@"splats",0));
                }
            }
            const std::string previousPhase=text(previous,@"phase");
            if(!config.resumeOnLaunch && (previousPhase=="paused" || previousPhase=="pausing")) intent=Intent::pause;
        }
        if(config.initiallyPaused) intent=Intent::pause;
        const int flags=fcntl(STDIN_FILENO,F_GETFL,0);
        if(flags>=0) fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK);
        signal(SIGPIPE,SIG_IGN); signal(SIGINT,signalHandler); signal(SIGTERM,signalHandler);
    }

    ~Worker() {
        releaseEngine();
        if(activity) { [NSProcessInfo.processInfo endActivity:activity]; [activity release]; }
        if(controlFD>=0) close(controlFD);
        if(lockFD>=0) close(lockFD);
    }

    int run() {
        try {
            publish("started");
            while(true) {
                @autoreleasepool {
                    pollControls();
                    if(intent==Intent::cancel) {
                        if(engine) saveCheckpoint("cancelling");
                        releaseEngine(); phase="cancelled"; commandState="completed"; message="Cancelado; se conserva el último checkpoint"; publish("cancelled"); return 130;
                    }
                    if(intent==Intent::pause) {
                        if(explicitCheckpoint && !engine && lastCheckpoint.empty()) initializeEngine();
                        if(engine) { phase="pausing"; message="Guardando antes de liberar la GPU"; publish("pausing"); saveCheckpoint("pausing"); releaseEngine(); }
                        if(phase!="paused") { phase="paused"; commandState="completed"; message="En pausa; checkpoint conservado y GPU liberada"; publish("paused"); }
                        if(explicitCheckpoint) { if(!lastCheckpoint.empty()) { explicitCheckpoint=false; commandState="completed"; publish("checkpointSaved"); } }
                        usleep(100000); continue;
                    }
                    if(!engine) initializeEngine();
                    pollControls();
                    if(intent==Intent::pause || intent==Intent::cancel) continue;
                    if(intent==Intent::exportModel || stats.iteration>=config.iterations) { exportModel(); return phase=="completed"?0:130; }
                    if(explicitCheckpoint) saveCheckpoint("running");
                    char error[2048]={};
                    if(!forma_gaussian_step(engine,&stats,error,sizeof(error))) throw std::runtime_error(error);
                    phase="running"; message="Optimizando Gaussian 3D con Metal en el Mac";
                    publish("progress",false);
                    if(config.checkpointSeconds>0 && now()-lastSaved>=config.checkpointSeconds) saveCheckpoint("running");
                }
            }
        } catch(const std::exception& error) {
            errorMessage=error.what();
            if(engine) {
                char checkpointError[2048]={};
                if(forma_gaussian_checkpoint(engine,checkpointPath().c_str(),checkpointError,sizeof(checkpointError))) {
                    lastCheckpoint=checkpointPath(); checkpointStep=stats.iteration;
                } else errorMessage+=" No se pudo guardar otro checkpoint: "+std::string(checkpointError);
            }
            releaseEngine(); phase="failed"; message="El proceso terminó; las fuentes y los checkpoints anteriores se conservan";
            publish("failed"); return 1;
        }
    }
};
} // namespace

int main(int argc,char* argv[]) {
    @autoreleasepool {
        if(argc==2 && (std::string(argv[1])=="--help" || std::string(argv[1])=="-h")) {
            const char* help="FormaGaussianWorker --config trabajo.json\nLocal macOS Metal worker. stdout: FORMA_GAUSSIAN {JSON}\nControls: NDJSON on stdin or append-only workspace/control.ndjson.\nCommands: pause, resume, checkpoint, export, cancel.\nState: workspace/status.json. Closing stdin does not cancel training.\n";
            (void)write(STDOUT_FILENO,help,std::strlen(help)); return 0;
        }
        try {
            if(argc!=3 || std::string(argv[1])!="--config") throw std::runtime_error("Uso: FormaGaussianWorker --config trabajo.json");
            Worker worker{Config(fs::path(argv[2]))};
            return worker.run();
        } catch(const std::exception& error) {
            const std::string line="FormaGaussianWorker: "+std::string(error.what())+'\n';
            (void)write(STDERR_FILENO,line.data(),line.size()); return 1;
        }
    }
}
