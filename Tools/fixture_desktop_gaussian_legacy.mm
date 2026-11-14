// Synthetic POSIX worker for controller liveness tests. No Metal/native engine.
#import <Foundation/Foundation.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <algorithm>
#include <string>

static volatile sig_atomic_t stopped = 0;
static void stopFixture(int) { stopped = 1; }
static NSDictionary *readJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static void writeJSON(NSString *path, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) _exit(71);
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3 || std::string(argv[1]) != "--config") return 64;
    NSDictionary *config = readJSON([NSString stringWithUTF8String:argv[2]]);
    NSString *workspace = config[@"workspacePath"], *jobID = config[@"jobID"];
    if (!workspace || !jobID) return 65;
    bool noLock = argc == 4 && std::string(argv[3]) == "--no-lock";
    int lock = open([[workspace stringByAppendingPathComponent:@"worker.lock"] fileSystemRepresentation], O_RDWR | O_CREAT, 0600);
    if (lock < 0 || (!noLock && flock(lock, LOCK_EX | LOCK_NB))) return 73;
    signal(SIGTERM, stopFixture); signal(SIGINT, stopFixture);
    int iteration = 0, target = [config[@"targetIterations"] intValue];
    bool paused = [config[@"initiallyPaused"] boolValue], completed = false;
    NSString *phase = paused ? @"paused" : @"running", *resultPath = nil, *checkpoint = nil;
    NSUInteger consumed = 0;
    NSString *controlPath = [workspace stringByAppendingPathComponent:@"control.ndjson"];
    if ([config[@"resumePath"] isKindOfClass:[NSString class]]) {
        // The native worker restores its command offset from its previous status.
        // This synthetic checkpoint restores the step and skips earlier commands.
        consumed = [NSData dataWithContentsOfFile:controlPath].length;
        NSString *text = [NSString stringWithContentsOfFile:config[@"resumePath"] encoding:NSUTF8StringEncoding error:nil];
        NSRange step = [text rangeOfString:@"step="];
        if (text && step.location != NSNotFound) iteration = [[text substringFromIndex:step.location + step.length] intValue];
    }
    while (!stopped) { @autoreleasepool {
        NSData *controls = [NSData dataWithContentsOfFile:controlPath];
        if (controls.length > consumed) {
            NSData *tail = [controls subdataWithRange:NSMakeRange(consumed, controls.length - consumed)];
            NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
            for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                if (!line.length) continue;
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if (![command[@"jobID"] isEqual:jobID]) continue;
                NSString *action = command[@"command"];
                if ([action isEqual:@"pause"] || [action isEqual:@"checkpoint"] || [action isEqual:@"export"]) {
                    checkpoint = [workspace stringByAppendingPathComponent:@"synthetic-checkpoint.txt"];
                    [[NSString stringWithFormat:@"SYNTHETIC NO GPU step=%d\n", iteration] writeToFile:checkpoint atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
                if ([action isEqual:@"pause"]) { paused = true; phase = @"paused"; }
                if ([action isEqual:@"resume"]) { paused = false; phase = @"running"; }
                if ([action isEqual:@"cancel"]) { phase = @"cancelled"; completed = true; }
                if ([action isEqual:@"export"]) {
                    resultPath = [workspace stringByAppendingPathComponent:@"exports/synthetic-only"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:resultPath withIntermediateDirectories:YES attributes:nil error:nil];
                    NSMutableString *ply = [NSMutableString stringWithString:@"ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\n"];
                    for (int i=0; i<3; i++) [ply appendFormat:@"property float f_dc_%d\n", i];
                    for (int i=0; i<45; i++) [ply appendFormat:@"property float f_rest_%d\n", i];
                    [ply appendString:@"property float opacity\nproperty float scale_0\nproperty float scale_1\nproperty float scale_2\nproperty float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\nend_header\n"];
                    for (int i=0; i<62; i++) [ply appendFormat:@"%@%@", i==58 ? @"1" : @"0", i==61 ? @"\n" : @" "];
                    [ply writeToFile:[resultPath stringByAppendingPathComponent:@"gaussianas.ply"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    writeJSON([resultPath stringByAppendingPathComponent:@"gaussianas.json"], @{@"syntheticFixture": @YES, @"gpuUsed": @NO});
                    phase = @"completed"; completed = true;
                }
            }
            consumed = controls.length;
        }
        if (!paused && !completed) iteration = std::min(target, iteration + 1);
        NSMutableDictionary *status = [@{@"schemaVersion": @1, @"jobID": jobID, @"pid": @(getpid()),
            @"phase": phase, @"message": @"Synthetic POSIX fixture; no GPU", @"iteration": @(iteration),
            @"targetIterations": @(target), @"splats": @1, @"progress": @(double(iteration)/target),
            @"downscale": config[@"downscale"], @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
            @"checkpointStep": @(iteration), @"syntheticFixture": @YES} mutableCopy];
        if (checkpoint) status[@"checkpointPath"] = checkpoint;
        if (resultPath) status[@"resultPath"] = resultPath;
        writeJSON([workspace stringByAppendingPathComponent:@"status.json"], status);
        if (completed) break;
        usleep(30000);
    } }
    if (!noLock) flock(lock, LOCK_UN);
    close(lock);
    return 0;
} }
