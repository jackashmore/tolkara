// Diagnostic and opt-in (launch argument --metal-audit): logs every Metal
// object the guest asks the device for that comes back nil, with the request's
// storage mode and size and the error when there is one, and counts requests in
// macOS's Managed storage mode. Results are passed through unchanged; nothing
// here alters what the guest gets. Installed after ManagedStorage.m's hooks so
// it sees what the guest finally receives.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
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

// The guest's drawables: how long each nextDrawable waits and what it returns,
// with the layer's state when it returns nil (it times out after a second when
// the layer cannot vend one).
static id<CAMetalDrawable> (*nextDrawable)(id,SEL);
static atomic_uint drawableCalls, drawableNils;
static NSString *layerState(CAMetalLayer *layer) {
    CALayer *top=layer; unsigned depth=0;
    while (top.superlayer && depth<64) { top=top.superlayer; depth++; }
    CGSize size=layer.drawableSize; CGRect bounds=layer.bounds;
    return [NSString stringWithFormat:@"drawableSize=%gx%g bounds=%gx%g scale=%g format=%lu device=%@ hidden=%d opacity=%g depth=%u top=%@ topDelegate=%@ maxDrawables=%lu timeout=%d framebufferOnly=%d",
        size.width,size.height,bounds.size.width,bounds.size.height,layer.contentsScale,(unsigned long)layer.pixelFormat,layer.device.name,
        (int)layer.hidden,layer.opacity,depth,NSStringFromClass(top.class),NSStringFromClass([(id)top.delegate class]),
        (unsigned long)layer.maximumDrawableCount,(int)layer.allowsNextDrawableTimeout,(int)layer.framebufferOnly];
}
static id<CAMetalDrawable> auditNextDrawable(id layer, SEL selector) {
    unsigned call=atomic_fetch_add(&drawableCalls,1)+1;
    double start=CACurrentMediaTime();
    id<CAMetalDrawable> drawable=nextDrawable(layer,selector);
    double waited=(CACurrentMediaTime()-start)*1000;
    if (!drawable) {
        unsigned count=atomic_fetch_add(&drawableNils,1)+1;
        if (count<=12 || count%25==0) AKLog(@"Metal audit: nextDrawable %u returned nil after %.0f ms (nil %u) main=%d %@",call,waited,count,(int)NSThread.isMainThread,layerState(layer));
    } else if (call<=3 || call==60 || waited>100) {
        AKLog(@"Metal audit: nextDrawable %u -> %lux%lu after %.0f ms main=%d",call,(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height,waited,(int)NSThread.isMainThread);
    }
    return drawable;
}
// Command buffers that the GPU ends with an error, and the first commits.
static void (*commit)(id,SEL);
static atomic_uint commits, failures;
static void auditCommit(id<MTLCommandBuffer> command, SEL selector) {
    unsigned count=atomic_fetch_add(&commits,1)+1;
    if (count<=3 || count==100 || count==1000) AKLog(@"Metal audit: command buffer %u committed",count);
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status!=MTLCommandBufferStatusError) return;
        unsigned failed=atomic_fetch_add(&failures,1)+1;
        if (failed<=16) AKLog(@"Metal audit: command buffer %u failed: %@",count,done.error);
    }];
    commit(command,selector);
}

// Every other way to make a pipeline (options and reflection, or asynchronous
// with a completion handler) and every way to take a function from a library:
// the guest's worker threads compile pipelines while its first frame waits.
static atomic_uint pipelines, pipelineNils;
static _Atomic double slowest;
static NSString *describe(id object) {
    if (!object) return @"(nil)";
    if ([object isKindOfClass:MTLRenderPipelineDescriptor.class]) {
        MTLRenderPipelineDescriptor *d=object;
        return [NSString stringWithFormat:@"render '%@' vertex=%@ fragment=%@ archives=%lu",d.label,d.vertexFunction.name,d.fragmentFunction.name,(unsigned long)d.binaryArchives.count];
    }
    if ([object isKindOfClass:MTLComputePipelineDescriptor.class]) {
        MTLComputePipelineDescriptor *d=object;
        return [NSString stringWithFormat:@"compute '%@' function=%@ archives=%lu",d.label,d.computeFunction.name,(unsigned long)d.binaryArchives.count];
    }
    if ([object conformsToProtocol:@protocol(MTLFunction)]) return [NSString stringWithFormat:@"function %@",((id<MTLFunction>)object).name];
    if ([object respondsToSelector:@selector(label)]) return [NSString stringWithFormat:@"%@ '%@'",NSStringFromClass([object class]),[object label]];
    return NSStringFromClass([object class]);
}
static void notePipeline(NSString *how, id request, id result, NSError *error, double start, unsigned long options) {
    double elapsed=CACurrentMediaTime()-start;
    unsigned count=atomic_fetch_add(&pipelines,1)+1;
    double previous=atomic_load(&slowest);
    while (elapsed>previous && !atomic_compare_exchange_weak(&slowest,&previous,elapsed)) {}
    if (!result) {
        unsigned failed=atomic_fetch_add(&pipelineNils,1)+1;
        if (failed<=64) AKLog(@"Metal audit: nil pipeline from %@ after %.0f ms options=%#lx %@ error=%@ (pipeline %u, nil %u)",how,elapsed*1000,options,describe(request),error,count,failed);
    } else if (elapsed>2) AKLog(@"Metal audit: pipeline %u took %.1f s (%@) %@",count,elapsed,how,describe(request));
    if (count==1 || count%250==0) AKLog(@"Metal audit: %u pipelines so far, %u nil, slowest %.0f ms",count,atomic_load(&pipelineNils),atomic_load(&slowest)*1000);
}
typedef id (*OptionsCreator)(id,SEL,id,NSUInteger,void *,NSError *__autoreleasing *) RETAINED;
typedef void (^Done2)(id,NSError *);
typedef void (^Done3)(id,id,NSError *);
typedef void (*Async2)(id,SEL,id,Done2);
typedef void (*Async3)(id,SEL,id,NSUInteger,Done3);
static IMP optionsOriginal[3], async2Original[2], async3Original[5];
#define OPTIONS_HOOK(n) \
static id optionsHook##n(id device, SEL selector, id request, NSUInteger options, void *reflection, NSError *__autoreleasing *error) RETAINED; \
static id optionsHook##n(id device, SEL selector, id request, NSUInteger options, void *reflection, NSError *__autoreleasing *error) { \
    NSError *local=nil; double start=CACurrentMediaTime(); \
    id result=((OptionsCreator)optionsOriginal[n])(device,selector,request,options,reflection,&local); \
    if (error) *error=local; \
    notePipeline(NSStringFromSelector(selector),request,result,local,start,options); \
    return result; \
}
OPTIONS_HOOK(0) OPTIONS_HOOK(1) OPTIONS_HOOK(2)
#define ASYNC2_HOOK(n) \
static void async2Hook##n(id device, SEL selector, id request, Done2 done) { \
    double start=CACurrentMediaTime(); NSString *how=NSStringFromSelector(selector); \
    ((Async2)async2Original[n])(device,selector,request,^(id result, NSError *error) { \
        notePipeline(how,request,result,error,start,0); if (done) done(result,error); }); \
}
ASYNC2_HOOK(0) ASYNC2_HOOK(1)
#define ASYNC3_HOOK(n) \
static void async3Hook##n(id device, SEL selector, id request, NSUInteger options, Done3 done) { \
    double start=CACurrentMediaTime(); NSString *how=NSStringFromSelector(selector); \
    ((Async3)async3Original[n])(device,selector,request,options,^(id result, id reflection, NSError *error) { \
        notePipeline(how,request,result,error,start,options); if (done) done(result,reflection,error); }); \
}
ASYNC3_HOOK(0) ASYNC3_HOOK(1) ASYNC3_HOOK(2) ASYNC3_HOOK(3) ASYNC3_HOOK(4)

// Functions taken from the guest's libraries: a name a library does not carry
// gives nil.
typedef id (*NamedFunction)(id,SEL,NSString *) RETAINED;
typedef id (*ConstantFunction)(id,SEL,NSString *,id,NSError *__autoreleasing *) RETAINED;
typedef id (*DescriptorFunction)(id,SEL,id,NSError *__autoreleasing *) RETAINED;
typedef void (*AsyncConstantFunction)(id,SEL,NSString *,id,Done2);
typedef id (*LibraryLoader)(id,SEL,dispatch_data_t,NSError *__autoreleasing *) RETAINED;
static NamedFunction namedFunction;
static ConstantFunction constantFunction;
static DescriptorFunction descriptorFunction;
static AsyncConstantFunction asyncConstantFunction;
static Async2 asyncDescriptorFunction;
static LibraryLoader libraryLoader;
static atomic_uint functionNils;
static void noteFunction(NSString *how, NSString *name, id library, id result, NSError *error) {
    if (result) return;
    unsigned failed=atomic_fetch_add(&functionNils,1)+1;
    if (failed<=64) AKLog(@"Metal audit: nil function %@ from %@ (%@ with %lu functions) error=%@ (nil %u)",name,how,
        NSStringFromClass([library class]),(unsigned long)[[library functionNames] count],error,failed);
}
static id auditNamedFunction(id library, SEL selector, NSString *name) RETAINED;
static id auditNamedFunction(id library, SEL selector, NSString *name) {
    id result=namedFunction(library,selector,name); noteFunction(@"newFunctionWithName:",name,library,result,nil); return result;
}
static id auditConstantFunction(id library, SEL selector, NSString *name, id constants, NSError *__autoreleasing *error) RETAINED;
static id auditConstantFunction(id library, SEL selector, NSString *name, id constants, NSError *__autoreleasing *error) {
    NSError *local=nil; id result=constantFunction(library,selector,name,constants,&local); if (error) *error=local;
    noteFunction(@"newFunctionWithName:constantValues:error:",name,library,result,local); return result;
}
static id auditDescriptorFunction(id library, SEL selector, MTLFunctionDescriptor *descriptor, NSError *__autoreleasing *error) RETAINED;
static id auditDescriptorFunction(id library, SEL selector, MTLFunctionDescriptor *descriptor, NSError *__autoreleasing *error) {
    NSError *local=nil; id result=descriptorFunction(library,selector,descriptor,&local); if (error) *error=local;
    noteFunction(@"newFunctionWithDescriptor:error:",descriptor.name,library,result,local); return result;
}
static void auditAsyncConstantFunction(id library, SEL selector, NSString *name, id constants, Done2 done) {
    asyncConstantFunction(library,selector,name,constants,^(id result, NSError *error) {
        noteFunction(@"newFunctionWithName:constantValues:completionHandler:",name,library,result,error); if (done) done(result,error); });
}
static void auditAsyncDescriptorFunction(id library, SEL selector, MTLFunctionDescriptor *descriptor, Done2 done) {
    NSString *name=descriptor.name;
    asyncDescriptorFunction(library,selector,descriptor,^(id result, NSError *error) {
        noteFunction(@"newFunctionWithDescriptor:completionHandler:",name,library,result,error); if (done) done(result,error); });
}
static void hookLibraryClass(Class cls) {
    static Class hooked;
    @synchronized(MTLRenderPipelineDescriptor.class) {
        if (hooked==cls) return;
        if (hooked) { AKLog(@"Metal audit: a second library class %@ is not audited (first %@)",NSStringFromClass(cls),NSStringFromClass(hooked)); return; }
        hooked=cls;
    }
    AKLog(@"Metal audit: auditing functions of library class %@",NSStringFromClass(cls));
    replace(cls,@selector(newFunctionWithName:),(IMP)auditNamedFunction,(void **)&namedFunction);
    replace(cls,@selector(newFunctionWithName:constantValues:error:),(IMP)auditConstantFunction,(void **)&constantFunction);
    replace(cls,@selector(newFunctionWithDescriptor:error:),(IMP)auditDescriptorFunction,(void **)&descriptorFunction);
    replace(cls,@selector(newFunctionWithName:constantValues:completionHandler:),(IMP)auditAsyncConstantFunction,(void **)&asyncConstantFunction);
    replace(cls,@selector(newFunctionWithDescriptor:completionHandler:),(IMP)auditAsyncDescriptorFunction,(void **)&asyncDescriptorFunction);
}
static id auditLibrary(id device, SEL selector, dispatch_data_t data, NSError *__autoreleasing *error) RETAINED;
static id auditLibrary(id device, SEL selector, dispatch_data_t data, NSError *__autoreleasing *error) {
    NSError *local=nil;
    id library=libraryLoader(device,selector,data,&local);
    if (error) *error=local;
    if (library) hookLibraryClass(object_getClass(library));
    else noteNil([NSString stringWithFormat:@"library from %zu bytes error=%@",dispatch_data_get_size(data),local]);
    return library;
}

void AKInstallMetalAudit(Class device, id<MTLDevice> instance) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        if (![NSProcessInfo.processInfo.arguments containsObject:@"--metal-audit"]) return;
        AKLog(@"Metal audit: logging nil results, Managed storage requests, drawables and failed command buffers (--metal-audit)");
        replace(CAMetalLayer.class,@selector(nextDrawable),(IMP)auditNextDrawable,(void **)&nextDrawable);
        // A command buffer of this device gives the class the guest's commits use.
        id<MTLCommandBuffer> sample=[[instance newCommandQueue] commandBuffer];
        if (sample) replace(object_getClass(sample),@selector(commit),(IMP)auditCommit,(void **)&commit);
        replace(device,@selector(newBufferWithLength:options:),(IMP)auditBuffer,(void **)&buffer);
        replace(device,@selector(newBufferWithBytes:length:options:),(IMP)auditBytes,(void **)&bytesBuffer);
        replace(device,@selector(newBufferWithBytesNoCopy:length:options:deallocator:),(IMP)auditNoCopy,(void **)&noCopyBuffer);
        replace(device,@selector(newTextureWithDescriptor:),(IMP)auditTexture,(void **)&texture);
        replace(device,@selector(newHeapWithDescriptor:),(IMP)auditHeap,(void **)&heap);
        replace(device,@selector(newDepthStencilStateWithDescriptor:),(IMP)auditDepthStencil,(void **)&depthStencil);
        replace(device,@selector(newSamplerStateWithDescriptor:),(IMP)auditSampler,(void **)&sampler);
        replace(device,@selector(newRenderPipelineStateWithDescriptor:error:),(IMP)auditRenderPipeline,(void **)&renderPipeline);
        replace(device,@selector(newComputePipelineStateWithFunction:error:),(IMP)auditComputePipeline,(void **)&computePipeline);
        replace(device,@selector(newRenderPipelineStateWithDescriptor:options:reflection:error:),(IMP)optionsHook0,(void **)&optionsOriginal[0]);
        replace(device,@selector(newComputePipelineStateWithFunction:options:reflection:error:),(IMP)optionsHook1,(void **)&optionsOriginal[1]);
        replace(device,@selector(newComputePipelineStateWithDescriptor:options:reflection:error:),(IMP)optionsHook2,(void **)&optionsOriginal[2]);
        replace(device,@selector(newRenderPipelineStateWithDescriptor:completionHandler:),(IMP)async2Hook0,(void **)&async2Original[0]);
        replace(device,@selector(newComputePipelineStateWithFunction:completionHandler:),(IMP)async2Hook1,(void **)&async2Original[1]);
        replace(device,@selector(newRenderPipelineStateWithDescriptor:options:completionHandler:),(IMP)async3Hook0,(void **)&async3Original[0]);
        replace(device,@selector(newComputePipelineStateWithFunction:options:completionHandler:),(IMP)async3Hook1,(void **)&async3Original[1]);
        replace(device,@selector(newComputePipelineStateWithDescriptor:options:completionHandler:),(IMP)async3Hook2,(void **)&async3Original[2]);
        replace(device,@selector(newRenderPipelineStateWithTileDescriptor:options:completionHandler:),(IMP)async3Hook3,(void **)&async3Original[3]);
        replace(device,@selector(newRenderPipelineStateWithMeshDescriptor:options:completionHandler:),(IMP)async3Hook4,(void **)&async3Original[4]);
        // After Devices.m's library loader, so the libraries seen are what the guest gets.
        replace(device,@selector(newLibraryWithData:error:),(IMP)auditLibrary,(void **)&libraryLoader);
    });
}
