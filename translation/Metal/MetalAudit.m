// Diagnostic and opt-in (launch argument --metal-audit): logs every Metal
// object the guest asks the device for that comes back nil, with the request's
// storage mode and size and the error when there is one, and counts requests in
// macOS's Managed storage mode. Results are passed through unchanged; nothing
// here alters what the guest gets. Installed after ManagedStorage.m's hooks so
// it sees what the guest finally receives.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "AKSupport.h"

#define RETAINED __attribute__((ns_returns_retained))
typedef id (*DescriptorCreator)(id,SEL,id) RETAINED;
typedef id (*DescriptorErrorCreator)(id,SEL,id,NSError *__autoreleasing *) RETAINED;
typedef id (*LengthCreator)(id,SEL,NSUInteger,MTLResourceOptions) RETAINED;
typedef id (*BytesCreator)(id,SEL,const void *,NSUInteger,MTLResourceOptions) RETAINED;
typedef id (*NoCopyCreator)(id,SEL,void *,NSUInteger,MTLResourceOptions,id) RETAINED;
static DescriptorCreator texture, heap, depthStencil, sampler;
static DescriptorErrorCreator renderPipeline, computePipeline;
static LengthCreator buffer;
static BytesCreator bytesBuffer;
static NoCopyCreator noCopyBuffer;
static atomic_uint nils, managed;

static void replace(Class cls, SEL selector, IMP replacement, void **original) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) { AKLog(@"Metal audit: the device has no %@",NSStringFromSelector(selector)); return; }
    *original=(void *)method_getImplementation(method);
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
}
static void noteManaged(unsigned long mode, NSString *what) {
    unsigned count=atomic_fetch_add(&managed,1)+1;
    if (mode==1 && (count<=8 || (count&(count-1))==0)) AKLog(@"Metal audit: Managed storage request %u (%@)",count,what);
}
static void noteNil(NSString *what) {
    unsigned count=atomic_fetch_add(&nils,1)+1;
    if (count<=64) AKLog(@"Metal audit: nil %@ (nil result %u)",what,count);
}
static NSString *options(MTLResourceOptions value) {
    return [NSString stringWithFormat:@"storage=%lu cache=%lu hazard=%lu",
        (unsigned long)((value>>4)&0xF),(unsigned long)(value&0xF),(unsigned long)((value>>8)&0x3)];
}

static id auditBuffer(id device, SEL selector, NSUInteger length, MTLResourceOptions opts) RETAINED;
static id auditBuffer(id device, SEL selector, NSUInteger length, MTLResourceOptions opts) {
    if (((opts>>4)&0xF)==1) noteManaged(1,[NSString stringWithFormat:@"buffer %lu bytes",(unsigned long)length]);
    id result=buffer(device,selector,length,opts);
    if (!result) noteNil([NSString stringWithFormat:@"buffer length=%lu %@",(unsigned long)length,options(opts)]);
    return result;
}
static id auditBytes(id device, SEL selector, const void *bytes, NSUInteger length, MTLResourceOptions opts) RETAINED;
static id auditBytes(id device, SEL selector, const void *bytes, NSUInteger length, MTLResourceOptions opts) {
    if (((opts>>4)&0xF)==1) noteManaged(1,[NSString stringWithFormat:@"buffer with bytes %lu",(unsigned long)length]);
    id result=bytesBuffer(device,selector,bytes,length,opts);
    if (!result) noteNil([NSString stringWithFormat:@"buffer with bytes length=%lu %@",(unsigned long)length,options(opts)]);
    return result;
}
static id auditNoCopy(id device, SEL selector, void *bytes, NSUInteger length, MTLResourceOptions opts, id deallocator) RETAINED;
static id auditNoCopy(id device, SEL selector, void *bytes, NSUInteger length, MTLResourceOptions opts, id deallocator) {
    if (((opts>>4)&0xF)==1) noteManaged(1,[NSString stringWithFormat:@"no-copy buffer %lu",(unsigned long)length]);
    id result=noCopyBuffer(device,selector,bytes,length,opts,deallocator);
    if (!result) noteNil([NSString stringWithFormat:@"no-copy buffer length=%lu %@ page-aligned=%d",(unsigned long)length,options(opts),(int)(((uintptr_t)bytes&0x3FFF)==0)]);
    return result;
}
static id auditTexture(id device, SEL selector, MTLTextureDescriptor *descriptor) RETAINED;
static id auditTexture(id device, SEL selector, MTLTextureDescriptor *descriptor) {
    if (descriptor.storageMode==1) noteManaged(1,[NSString stringWithFormat:@"texture %lux%lu",(unsigned long)descriptor.width,(unsigned long)descriptor.height]);
    id result=texture(device,selector,descriptor);
    if (!result) noteNil([NSString stringWithFormat:@"texture type=%lu format=%lu %lux%lux%lu mips=%lu array=%lu samples=%lu storage=%lu usage=%#lx",
        (unsigned long)descriptor.textureType,(unsigned long)descriptor.pixelFormat,(unsigned long)descriptor.width,(unsigned long)descriptor.height,
        (unsigned long)descriptor.depth,(unsigned long)descriptor.mipmapLevelCount,(unsigned long)descriptor.arrayLength,(unsigned long)descriptor.sampleCount,
        (unsigned long)descriptor.storageMode,(unsigned long)descriptor.usage]);
    return result;
}
static id auditHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) RETAINED;
static id auditHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) {
    if (descriptor.storageMode==1) noteManaged(1,[NSString stringWithFormat:@"heap %lu bytes",(unsigned long)descriptor.size]);
    id result=heap(device,selector,descriptor);
    if (!result) noteNil([NSString stringWithFormat:@"heap size=%lu storage=%lu type=%ld",(unsigned long)descriptor.size,(unsigned long)descriptor.storageMode,(long)descriptor.type]);
    return result;
}
static id auditDepthStencil(id device, SEL selector, id descriptor) RETAINED;
static id auditDepthStencil(id device, SEL selector, id descriptor) {
    id result=depthStencil(device,selector,descriptor);
    if (!result) noteNil(@"depth-stencil state");
    return result;
}
static id auditSampler(id device, SEL selector, MTLSamplerDescriptor *descriptor) RETAINED;
static id auditSampler(id device, SEL selector, MTLSamplerDescriptor *descriptor) {
    id result=sampler(device,selector,descriptor);
    if (!result) noteNil([NSString stringWithFormat:@"sampler state argument-buffers=%d border=%lu",(int)descriptor.supportArgumentBuffers,(unsigned long)descriptor.borderColor]);
    return result;
}
static id auditRenderPipeline(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, NSError *__autoreleasing *error) RETAINED;
static id auditRenderPipeline(id device, SEL selector, MTLRenderPipelineDescriptor *descriptor, NSError *__autoreleasing *error) {
    NSError *local=nil;
    id result=renderPipeline(device,selector,descriptor,&local);
    if (error) *error=local;
    if (!result) noteNil([NSString stringWithFormat:@"render pipeline '%@' vertex=%@ fragment=%@ error=%@",descriptor.label,
        descriptor.vertexFunction.name,descriptor.fragmentFunction.name,local.localizedDescription]);
    return result;
}
static id auditComputePipeline(id device, SEL selector, id<MTLFunction> function, NSError *__autoreleasing *error) RETAINED;
static id auditComputePipeline(id device, SEL selector, id<MTLFunction> function, NSError *__autoreleasing *error) {
    NSError *local=nil;
    id result=computePipeline(device,selector,function,&local);
    if (error) *error=local;
    if (!result) noteNil([NSString stringWithFormat:@"compute pipeline %@ error=%@",function.name,local.localizedDescription]);
    return result;
}

void AKInstallMetalAudit(Class device) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        if (![NSProcessInfo.processInfo.arguments containsObject:@"--metal-audit"]) return;
        AKLog(@"Metal audit: logging nil results and Managed storage requests (--metal-audit)");
        replace(device,@selector(newBufferWithLength:options:),(IMP)auditBuffer,(void **)&buffer);
        replace(device,@selector(newBufferWithBytes:length:options:),(IMP)auditBytes,(void **)&bytesBuffer);
        replace(device,@selector(newBufferWithBytesNoCopy:length:options:deallocator:),(IMP)auditNoCopy,(void **)&noCopyBuffer);
        replace(device,@selector(newTextureWithDescriptor:),(IMP)auditTexture,(void **)&texture);
        replace(device,@selector(newHeapWithDescriptor:),(IMP)auditHeap,(void **)&heap);
        replace(device,@selector(newDepthStencilStateWithDescriptor:),(IMP)auditDepthStencil,(void **)&depthStencil);
        replace(device,@selector(newSamplerStateWithDescriptor:),(IMP)auditSampler,(void **)&sampler);
        replace(device,@selector(newRenderPipelineStateWithDescriptor:error:),(IMP)auditRenderPipeline,(void **)&renderPipeline);
        replace(device,@selector(newComputePipelineStateWithFunction:error:),(IMP)auditComputePipeline,(void **)&computePipeline);
    });
}
