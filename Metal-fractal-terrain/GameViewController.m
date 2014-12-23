

#import "GameViewController.h"

@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;

#include <stdlib.h>
#include <time.h>

// The max number of command buffers in flight
static const NSUInteger g_max_inflight_buffers = 3;

// Max API memory buffer size.
static const size_t MAX_BYTES_PER_FRAME = 8192*8192;

float heights[257][257];
float vertices[257][257][6];
float terrainVertexData[4645152];



typedef struct
{
    matrix_float4x4 modelview_projection_matrix;
    matrix_float4x4 normal_matrix;
} uniforms_t;

@implementation GameViewController
{
    // layer
    CAMetalLayer *_metalLayer;
    id <CAMetalDrawable> _currentDrawable;
    BOOL _layerSizeDidUpdate;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    
    // controller
    CADisplayLink *_timer;
    BOOL _gameLoopPaused;
    dispatch_semaphore_t _inflight_semaphore;
    id <MTLBuffer> _dynamicConstantBuffer;
    uint8_t _constantDataBufferIndex;
    
    // renderer
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLBuffer> _vertexBuffer;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _depthTex;
    id <MTLTexture> _msaaTex;
    
    // uniforms
    matrix_float4x4 _projectionMatrix;
    matrix_float4x4 _viewMatrix;
    uniforms_t _uniform_buffer;
    float _rotation;
}

- (void)dealloc
{
    [_timer invalidate];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    _constantDataBufferIndex = 0;
    _inflight_semaphore = dispatch_semaphore_create(g_max_inflight_buffers);
    
    for (int i=0; i<257; i++) {
        for (int j=0; j<257; j++) {
            heights[i][j]=0;
        }
    }
    //Trying fractal terrain.
    float maxHeight=6;
    float heightDegrade=2;
    float heightConterOffset=1.5;
    int range=256;
    srand(time(NULL));
    for (int i=0; i<8; i++) {
        for (int a=range/2; a<256; a+=range) {
            for (int b=range/2; b<256; b+=range) {
                heights[a][b]=(heights[a-range/2][b-range/2]+
                               heights[a+range/2][b-range/2]+
                               heights[a+range/2][b+range/2]+
                               heights[a-range/2][b+range/2])/4;
                heights[a][b]+=maxHeight*(rand()%1000+1)/1000-maxHeight/heightConterOffset;
            }
        }
        for (int a=0; a<=256; a+=range/2) {
            for (int b=0; b<=256; b+=range/2) {
                if ((a+b)%range!=0) {
                    float upper,lower,left,right;
                    if (a==0) upper=0;
                    else upper=heights[a-range/2][b];
                    if (a==256) lower=0;
                    else lower=heights[a+range/2][b];
                    if (b==0) left=0;
                    else left=heights[a][b-range/2];
                    if (b==256) right=0;
                    else right=heights[a][b+range/2];
                    heights[a][b]=(upper+lower+left+right)/4;
                    heights[a][b]+=maxHeight*(rand()%1000+1)/1000-maxHeight/heightConterOffset;
                }
            }
        }
        maxHeight/=heightDegrade;
        range/=2;
    }
    for(int i=0;i<=256;i++){
        for(int j=0;j<=256;j++){
            vertices[i][j][0]=16*(float)j/256-8;
            vertices[i][j][1]=16*(float)i/256-8;
            vertices[i][j][2]=heights[i][j];
        }
    }
    for(int i=1;i<256;i++){
        for (int j=1; j<256; j++) {
            vector_float3 up=(vector_float3){vertices[i][j][0]-vertices[i-1][j][0],
                vertices[i][j][1]-vertices[i-1][j][1],
                vertices[i][j][2]-vertices[i-1][j][2]};
            vector_float3 left=(vector_float3){vertices[i][j][0]-vertices[i][j-1][0],
                vertices[i][j][1]-vertices[i][j-1][1],
                vertices[i][j][2]-vertices[i][j-1][2]};
            vector_float3 upright=(vector_float3){vertices[i][j][0]-vertices[i-1][j+1][0],
                vertices[i][j][1]-vertices[i-1][j+1][1],
                vertices[i][j][2]-vertices[i-1][j+1][2]};
            vector_float3 right=(vector_float3){vertices[i][j][0]-vertices[i][j+1][0],
                vertices[i][j][1]-vertices[i][j+1][1],
                vertices[i][j][2]-vertices[i][j+1][2]};
            vector_float3 lower=(vector_float3){vertices[i][j][0]-vertices[i+1][j][0],
                vertices[i][j][1]-vertices[i+1][j][1],
                vertices[i][j][2]-vertices[i+1][j][2]};
            vector_float3 lowerleft=(vector_float3){vertices[i][j][0]-vertices[i+1][j-1][0],
                vertices[i][j][1]-vertices[i+1][j-1][1],
                vertices[i][j][2]-vertices[i+1][j-1][2]};
            vector_float3 sumnormal=vector_cross(left,up)+
            vector_cross(up,upright)+
            vector_cross(upright,right)+
            vector_cross(right,lower)+
            vector_cross(lower,lowerleft)+
            vector_cross(lowerleft,left);
            sumnormal=vector_normalize(sumnormal);
            vertices[i][j][3]=sumnormal[0];
            vertices[i][j][4]=sumnormal[1];
            vertices[i][j][5]=sumnormal[2];
        }
    }
    
    for (int i=1; i<255; i++) {
        for (int j=1; j<255; j++) {
            int startIndex=((i-1)*254+j-1)*72;
            float normal_coef=-1;
            for (int a=0; a<2; a++) {
                int tempStart=startIndex+36*a;
                for (int b=0; b<3; b++) {
                    terrainVertexData[tempStart+b]=vertices[i][j][b];
                    terrainVertexData[tempStart+6+b]=vertices[i][j+1][b];
                    terrainVertexData[tempStart+12+b]=vertices[i+1][j][b];
                    terrainVertexData[tempStart+18+b]=vertices[i][j+1][b];
                    terrainVertexData[tempStart+24+b]=vertices[i+1][j+1][b];
                    terrainVertexData[tempStart+30+b]=vertices[i+1][j][b];
                }
                for (int b=3; b<6; b++) {
                    terrainVertexData[tempStart+b]=vertices[i][j][b]*normal_coef;
                    terrainVertexData[tempStart+6+b]=vertices[i][j+1][b]*normal_coef;
                    terrainVertexData[tempStart+12+b]=vertices[i+1][j][b]*normal_coef;
                    terrainVertexData[tempStart+18+b]=vertices[i][j+1][b]*normal_coef;
                    terrainVertexData[tempStart+24+b]=vertices[i+1][j+1][b]*normal_coef;
                    terrainVertexData[tempStart+30+b]=vertices[i+1][j][b]*normal_coef;
                }
                normal_coef*=-1;
            }
        }
    }
    
    //Try fractal terrain until here.
    
    [self _setupMetal];
    [self _loadAssets];
    
    _rotation = 22.5f * (M_PI / 180.0f);
    
    _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(_gameloop)];
    [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)_setupMetal
{
    // Find a usable device
    _device = MTLCreateSystemDefaultDevice();
    
    // Create a new command queue
    _commandQueue = [_device newCommandQueue];
    
    // Load all the shader files with a metal file extension in the project
    _defaultLibrary = [_device newDefaultLibrary];
    
    // Setup metal layer and add as sub layer to view
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Change this to NO if the compute encoder is used as the last pass on the drawable texture
    _metalLayer.framebufferOnly = YES;
    
    // Add metal layer to the views layer hierarchy
    [_metalLayer setFrame:self.view.layer.frame];
    [self.view.layer addSublayer:_metalLayer];
    
    self.view.opaque = YES;
    self.view.backgroundColor = nil;
    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)_loadAssets
{
    // Allocate one region of memory for the uniform buffer
    _dynamicConstantBuffer = [_device newBufferWithLength:MAX_BYTES_PER_FRAME options:0];
    _dynamicConstantBuffer.label = @"UniformBuffer";
    
    // Load the fragment program into the library
    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"lighting_fragment"];
    
    // Load the vertex program into the library
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"lighting_vertex"];
    
    // Setup the vertex buffers
    _vertexBuffer = [_device newBufferWithBytes:terrainVertexData length:sizeof(terrainVertexData) options:MTLResourceOptionCPUCacheModeDefault];
    _vertexBuffer.label = @"Vertices";
    
    // Create a reusable pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    [pipelineStateDescriptor setSampleCount: 1];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    
    NSError* error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)setupRenderPassDescriptorForTexture:(id <MTLTexture>) texture
{
    if (_renderPassDescriptor == nil)
        _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    
    _renderPassDescriptor.colorAttachments[0].texture = texture;
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.65f, 0.65f, 0.65f, 1.0f);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    if (!_depthTex || (_depthTex && (_depthTex.width != texture.width || _depthTex.height != texture.height)))
    {
        //  If we need a depth texture and don't have one, or if the depth texture we have is the wrong size
        //  Then allocate one of the proper size
        
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat: MTLPixelFormatDepth32Float width: texture.width height: texture.height mipmapped: NO];
        _depthTex = [_device newTextureWithDescriptor: desc];
        _depthTex.label = @"Depth";
        
        _renderPassDescriptor.depthAttachment.texture = _depthTex;
        _renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        _renderPassDescriptor.depthAttachment.clearDepth = 1.0f;
        _renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    }
}

- (void)_render
{
    dispatch_semaphore_wait(_inflight_semaphore, DISPATCH_TIME_FOREVER);
    
    [self _update];
    
    // Create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";
    
    // obtain a drawable texture for this render pass and set up the renderpass descriptor for the command encoder to render into
    id <CAMetalDrawable> drawable = [self currentDrawable];
    [self setupRenderPassDescriptorForTexture:drawable.texture];
    
    // Create a render command encoder so we can render into something
    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
    renderEncoder.label = @"MyRenderEncoder";
    [renderEncoder setDepthStencilState:_depthState];
    
    // Set context state
    [renderEncoder pushDebugGroup:@"DrawCube"];
    [renderEncoder setRenderPipelineState:_pipelineState];
    [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0 ];
    [renderEncoder setVertexBuffer:_dynamicConstantBuffer offset:(sizeof(uniforms_t) * _constantDataBufferIndex) atIndex:1 ];
    
    // Tell the render context we want to draw our primitives
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:254*254*12 instanceCount:1];
    [renderEncoder popDebugGroup];
    
    // We're done encoding commands
    [renderEncoder endEncoding];
    
    // Call the view's completion handler which is required by the view since it will signal its semaphore and set up the next buffer
    __block dispatch_semaphore_t block_sema = _inflight_semaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_semaphore_signal(block_sema);
    }];
    
    // The renderview assumes it can now increment the buffer index and that the previous index won't be touched until we cycle back around to the same index
    _constantDataBufferIndex = (_constantDataBufferIndex + 1) % g_max_inflight_buffers;
    
    // Schedule a present once the framebuffer is complete
    [commandBuffer presentDrawable:drawable];
    
    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
}

- (void)_reshape
{
    // When reshape is called, update the view and projection matricies since this means the view orientation or size changed
    float aspect = fabsf(self.view.bounds.size.width / self.view.bounds.size.height);
    _projectionMatrix = matrix_from_perspective_fov_aspectLH(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0f);
    
    _viewMatrix = matrix_identity_float4x4;
}

- (void)_update
{
    matrix_float4x4 base_model = matrix_multiply(matrix_from_translation(0.0f, 0.0f, 5.0f), matrix_from_rotation(_rotation, 1.0f, 0.0f, 0.0f));
    matrix_float4x4 base_mv = matrix_multiply(_viewMatrix, base_model);
    matrix_float4x4 modelViewMatrix = matrix_multiply(base_mv, matrix_from_rotation(_rotation, 1.0f, 0.0f, 0.0f));
    
    _uniform_buffer.normal_matrix = matrix_invert(matrix_transpose(modelViewMatrix));
    _uniform_buffer.modelview_projection_matrix = matrix_multiply(_projectionMatrix, modelViewMatrix);
    
    // Load constant buffer data into appropriate buffer at current index
    uint8_t *bufferPointer = (uint8_t *)[_dynamicConstantBuffer contents] + (sizeof(uniforms_t) * _constantDataBufferIndex);
    memcpy(bufferPointer, &_uniform_buffer, sizeof(uniforms_t));
    
    
}

// The main game loop called by the CADisplayLine timer
- (void)_gameloop
{
    @autoreleasepool {
        if (_layerSizeDidUpdate)
        {
            CGFloat nativeScale = self.view.window.screen.nativeScale;
            CGSize drawableSize = self.view.bounds.size;
            drawableSize.width *= nativeScale;
            drawableSize.height *= nativeScale;
            _metalLayer.drawableSize = drawableSize;
            
            [self _reshape];
            _layerSizeDidUpdate = NO;
        }
        
        // draw
        [self _render];
        
        _currentDrawable = nil;
    }
}

// Called whenever view changes orientation or layout is changed
- (void)viewDidLayoutSubviews
{
    _layerSizeDidUpdate = YES;
    [_metalLayer setFrame:self.view.layer.frame];
}

#pragma mark Utilities

- (id <CAMetalDrawable>)currentDrawable
{
    while (_currentDrawable == nil)
    {
        _currentDrawable = [_metalLayer nextDrawable];
        if (!_currentDrawable)
        {
            NSLog(@"CurrentDrawable is nil");
        }
    }
    
    return _currentDrawable;
}

static matrix_float4x4 matrix_from_perspective_fov_aspectLH(const float fovY, const float aspect, const float nearZ, const float farZ)
{
    float yscale = 1.0f / tanf(fovY * 0.5f); // 1 / tan == cot
    float xscale = yscale / aspect;
    float q = farZ / (farZ - nearZ);
    
    matrix_float4x4 m = {
        .columns[0] = { xscale, 0.0f, 0.0f, 0.0f },
        .columns[1] = { 0.0f, yscale, 0.0f, 0.0f },
        .columns[2] = { 0.0f, 0.0f, q, 1.0f },
        .columns[3] = { 0.0f, 0.0f, q * -nearZ, 0.0f }
    };
    
    return m;
}

static matrix_float4x4 matrix_from_translation(float x, float y, float z)
{
    matrix_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (vector_float4) { x, y, z, 1.0 };
    return m;
}

static matrix_float4x4 matrix_from_rotation(float radians, float x, float y, float z)
{
    vector_float3 v = vector_normalize(((vector_float3){x, y, z}));
    float cos = cosf(radians);
    float cosp = 1.0f - cos;
    float sin = sinf(radians);
    
    matrix_float4x4 m = {
        .columns[0] = {
            cos + cosp * v.x * v.x,
            cosp * v.x * v.y + v.z * sin,
            cosp * v.x * v.z - v.y * sin,
            0.0f,
        },
        
        .columns[1] = {
            cosp * v.x * v.y - v.z * sin,
            cos + cosp * v.y * v.y,
            cosp * v.y * v.z + v.x * sin,
            0.0f,
        },
        
        .columns[2] = {
            cosp * v.x * v.z + v.y * sin,
            cosp * v.y * v.z - v.x * sin,
            cos + cosp * v.z * v.z,
            0.0f,
        },
        
        .columns[3] = { 0.0f, 0.0f, 0.0f, 1.0f
        }
    };
    return m;
}

@end
