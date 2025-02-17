unit KM_Render;
{$I KaM_Remake.inc}
interface
uses
  {$IFDEF WDC} Windows, Graphics, JPEG, {$ENDIF} //Lazarus doesn't have JPEG library yet -> FPReadJPEG?
  {$IFDEF Unix} LCLIntf, LCLType, OpenGLContext, {$ENDIF}
  Math, dglOpenGL, KromOGLUtils, KromUtils,
  KM_RenderControl, KM_RenderQuery, KM_RenderTypes;


const
  TEX_FORMAT_SIZE: array [TTexFormat] of Byte = (2, 4, 1);
  TEX_FILTER: array [TFilterType] of GLint = (GL_NEAREST, GL_LINEAR);

type
  TKMRenderMode = (rm2D, rm3D);

  //General OpenGL handling
  TRender = class
  private class var
    fLastBindedTextureId: Cardinal;
    fMaxTextureSize: Cardinal;
  private
    fRenderControl: TKMRenderControl;
    fOpenGL_Vendor, fOpenGL_Renderer, fOpenGL_Version: UnicodeString;
    fScreenX, fScreenY: Word;
    fBlind: Boolean;
    fQuery: TKMRenderQuery;
  public
    constructor Create(aRenderControl: TKMRenderControl; ScreenX,ScreenY: Integer; aVSync: Boolean);
    destructor Destroy; override;

    procedure SetRenderMode(aRenderMode: TKMRenderMode); //Switch between 2D and 3D perspectives

    class function GetMaxTexSize: Integer;
    class function GenerateTextureCommon(aMinFilter, aMagFilter: TFilterType): GLuint;
    class function GenTexture(DestX, DestY: Word; const Data: Pointer; Mode: TTexFormat; aMinFilter, aMagFilter: TFilterType): GLUint;
    class procedure DeleteTexture(aTex: GLUint);
    class procedure UpdateTexture(aTexture: GLuint; DestX, DestY: Word; Mode: TTexFormat; const Data: Pointer);
    class procedure BindTexture(aTexId: Cardinal);
    // This is pointless. OGL does its own RAM/VRAM management. To be deleted in 2021
    //class procedure FakeRender(aID: Cardinal);
    class property MaxTextureSize: Cardinal read fMaxTextureSize;

    property RendererVersion: UnicodeString read fOpenGL_Version;
    function IsOldGLVersion: Boolean;
    procedure DoPrintScreen(const aFileName: string);
    procedure Resize(aWidth, aHeight: Integer);

    property ScreenX: Word read fScreenX;
    property ScreenY: Word read fScreenY;
    property Blind: Boolean read fBlind;

    property Query: TKMRenderQuery read fQuery;

    procedure BeginFrame;
    procedure RenderBrightness(aValue: Byte);
    procedure EndFrame;
  end;

var
  gRender: TRender;


implementation
uses
  SysUtils, KM_Log;


{ TRender }
constructor TRender.Create(aRenderControl: TKMRenderControl; ScreenX,ScreenY: Integer; aVSync: Boolean);
begin
  inherited Create;

  fBlind := aRenderControl = nil;
  fRenderControl := aRenderControl;

  if not fBlind then
  begin
    fQuery := TKMRenderQuery.Create;

    fRenderControl.CreateRenderContext;

    glGetIntegerv(GL_MAX_TEXTURE_SIZE, @fMaxTextureSize); //Get max supported texture size by video adapter
    gLog.AddTime('GL_MAX_TEXTURE_SIZE = ' + IntToStr(fMaxTextureSize));

    glClearColor(0, 0, 0, 0); 	   //Background
    glClearStencil(0);
    glDepthFunc(GL_LEQUAL);
    glShadeModel(GL_SMOOTH);                 //Enables Smooth Color Shading
    glPolygonMode(GL_FRONT, GL_FILL);
    glEnable(GL_NORMALIZE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA); //Set alpha mode
    glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
    glEnable(GL_COLOR_MATERIAL);                 //Enable Materials
    glEnable(GL_TEXTURE_2D);                     // Enable Texture Mapping
    glDisable(GL_LIGHTING); //We don't need it
    //glEnable(GL_CULL_FACE);
    //glCullFace(GL_FRONT);

    fOpenGL_Vendor   := UnicodeString(glGetString(GL_VENDOR));   gLog.AddNoTime('OpenGL Vendor: '   + fOpenGL_Vendor);
    fOpenGL_Renderer := UnicodeString(glGetString(GL_RENDERER)); gLog.AddNoTime('OpenGL Renderer: ' + fOpenGL_Renderer);
    fOpenGL_Version  := UnicodeString(glGetString(GL_VERSION));  gLog.AddNoTime('OpenGL Version: '  + fOpenGL_Version);

    SetupVSync(aVSync);

    Resize(ScreenX, ScreenY);
  end;
end;


destructor TRender.Destroy;
begin
  if not fBlind then
  begin
    fRenderControl.DestroyRenderContext;
    fQuery.Free;
  end;

  inherited;
end;


//We have to use this method EVERY time we want to bind texture. Otherwise collisions could happen
//
//Do not bind same texture again, it can drastically change render performance
//F.e. on an average Map (Cube 256x256) when full map is shown in viewport
//there are only ~10k new texture binds, when all other ~30k binds can be skipped
class procedure TRender.BindTexture(aTexId: Cardinal);
begin
  if aTexId <> fLastBindedTextureId then
  begin
    glBindTexture(GL_TEXTURE_2D, aTexId);
    fLastBindedTextureId := aTexId;
  end;
end;


procedure TRender.Resize(aWidth, aHeight: Integer);
begin
  if fBlind then Exit;

  fScreenX := max(aWidth, 1);
  fScreenY := max(aHeight, 1);
  glViewport(0, 0, fScreenX, fScreenY);
end;


procedure TRender.SetRenderMode(aRenderMode: TKMRenderMode);
begin
  if fBlind then Exit;

  glMatrixMode(GL_PROJECTION); //Change Matrix Mode to Projection
  glLoadIdentity; //Reset View

  //In 2D mode we use Z-test to clip terrain shadows behind mountains
  //1 unit for each tile strip. 512 means we can handle up to 512x512 maps
  case aRenderMode of
    rm2D: glOrtho(0, fScreenX, fScreenY, 0, -100, 100);
    rm3D: gluPerspective(80, -fScreenX/fScreenY, 0.1, 5000);
  end;
  glMatrixMode(GL_MODELVIEW); //Return to the modelview matrix
  glLoadIdentity; //Reset View
end;


class function TRender.GenerateTextureCommon(aMinFilter, aMagFilter: TFilterType): GLuint;
var
  texture: GLuint;
begin
  Result := 0;
  if not Assigned(glGenTextures) then Exit;

  glGenTextures(1, @texture);
  BindTexture(texture);

  {Enable color blending into texture}
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
  //GL_MODULATE is our choice
  //GL_REPLACE is also available since version 1.1
  //can't use GL_REPLACE cos it disallows blending of texture with custom color (e.g. trees in FOW)

  {Use nearest filter to keep original KaM grainy look}
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, TEX_FILTER[aMinFilter]);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, TEX_FILTER[aMagFilter]);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);

  {Clamping UVs solves edge artifacts}
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);
  Result := texture;
end;


//Generate texture out of TCardinalArray
class function TRender.GenTexture(DestX, DestY: Word; const Data: Pointer; Mode: TTexFormat; aMinFilter, aMagFilter: TFilterType): GLUint;
begin
  Result := GenerateTextureCommon(aMinFilter, aMagFilter);
  UpdateTexture(Result, DestX, DestY, Mode, Data);
end;


class procedure TRender.DeleteTexture(aTex: GLUint);
begin
  glDeleteTextures(1, @aTex);
end;


class function TRender.GetMaxTexSize: Integer;
begin
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, @Result);
end;


//Update texture with TCardinalArray
class procedure TRender.UpdateTexture(aTexture: GLuint; DestX, DestY: Word; Mode: TTexFormat; const Data: Pointer);
begin
  if not Assigned(glTexImage2D) then Exit;

  Assert((DestX * DestY > 0) and (DestX = MakePOT(DestX)) and (DestY = MakePOT(DestY)),
         Format('Game designed to handle only POT textures. Texture size: [%d:%d]', [DestX,DestY]));

  BindTexture(aTexture);

  //GL_ALPHA   (0-0-0-8 bit) - 
  //GL_RGB5_A1 (5-5-5-1 bit) - 
  //GL_RGBA    (8-8-8-8 bit) - allows fuzzy shadows
  //Figures are before trimming - only ratio matters
  case Mode of
    //Base layer
    tfRGB5A1:  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB5_A1, DestX, DestY, 0, GL_RGBA, GL_UNSIGNED_BYTE, Data);
    //Base layer with alpha channel for shadows
    tfRGBA8:   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, DestX, DestY, 0, GL_RGBA, GL_UNSIGNED_BYTE, Data);
    //Team color layer (4 bit would be okay), but house construction steps need 8bit resolution
    tfAlpha8:  glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA,  DestX, DestY, 0, GL_RGBA, GL_UNSIGNED_BYTE, Data);
  end;
  BindTexture(0);
end;


//1.4 is considered to be our minimal requirement
function TRender.IsOldGLVersion: Boolean;
begin
  Result := not fBlind and not GL_VERSION_1_4;
end;


procedure TRender.DoPrintScreen(const aFileName: string);
{$IFDEF WDC}
var
  I, K, W, H: integer;
  jpg: TJpegImage;
  mkbmp: TBitMap;
  bmp: array of Cardinal;
{$ENDIF}
begin
{$IFDEF WDC}
  W := ScreenX;
  H := ScreenY;

  SetLength(bmp, W * H + 1);
  glReadPixels(0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, @bmp[0]);

  //Mirror verticaly
  for i := 0 to (H div 2) - 1 do
    for K := 0 to W - 1 do
      SwapInt(bmp[i * W + K], bmp[((H - 1) - i) * W + K]);

  mkbmp := TBitmap.Create;
  mkbmp.Handle := CreateBitmap(W, H, 1, 32, @bmp[0]);

  jpg := TJpegImage.Create;
  jpg.assign(mkbmp);
  jpg.ProgressiveEncoding := True;
  jpg.ProgressiveDisplay  := True;
  jpg.Performance         := jpBestQuality;
  jpg.CompressionQuality  := 90;
  jpg.Compress;
  jpg.SaveToFile(aFileName);

  jpg.Free;
  mkbmp.Free;
{$ENDIF}
end;


procedure TRender.BeginFrame;
begin
  if fBlind then Exit;

  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT or GL_STENCIL_BUFFER_BIT);
  SetRenderMode(rm2D);

  //RC.Activate for OSX
end;


//Render highlight overlay to make whole picture look brighter (more saturated)
procedure TRender.RenderBrightness(aValue: Byte);
begin
  if fBlind then Exit;

  //There will be no change to image anyway
  if aValue = 0 then Exit;

  BindTexture(0); // We have to reset texture to default (0), because it could be bind to any other texture (atlas)

  glLoadIdentity;
  glBlendFunc(GL_DST_COLOR, GL_ONE);
  glColor4f(aValue/20, aValue/20, aValue/20, aValue/20);
  glBegin(GL_QUADS);
    glkRect(0, 0, ScreenX, ScreenY);
  glEnd;

  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
end;


procedure TRender.EndFrame;
begin
  if fBlind then Exit;

  glFinish;
  fRenderControl.SwapBuffers;
end;


// This is pointless. OGL does its own RAM/VRAM management. To be deleted in 2021
{
//Fake Render from Atlas, to force copy of it into video RAM, where it is supposed to be
class procedure TRender.FakeRender(aID: Cardinal);
begin
  glColor4ub(0, 0, 0, 0);
  BindTexture(aID);

  glBegin(GL_TRIANGLES);
    glVertex2f(0, 0);
    glVertex2f(0, 0);
    glVertex2f(0, 0);
  glEnd;
end;
}


end.
