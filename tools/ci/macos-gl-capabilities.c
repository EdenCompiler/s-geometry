#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <stdio.h>

/* Consulta os perfis do próprio driver, sem depender do GLFW ou da imagem Lisp. */
static void json_string(const char *text)
{
    if (!text) {
        fputs("null", stdout);
        return;
    }
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p == '"' || *p == '\\') {
            putchar('\\');
            putchar(*p);
        } else if (*p < 32) {
            printf("\\u%04x", *p);
        } else {
            putchar(*p);
        }
    }
    putchar('"');
}

static void probe(CGLPixelFormatAttribute profile, int core)
{
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, profile, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    CGLError error = CGLChoosePixelFormat(attributes, &format, &count);
    if (error == kCGLNoError && format)
        error = CGLCreateContext(format, NULL, &context);
    if (error == kCGLNoError && context)
        error = CGLSetCurrentContext(context);

    const char *version = NULL;
    const char *vendor = NULL;
    const char *renderer = NULL;
    int major = 0, minor = 0;
    if (error == kCGLNoError && context) {
        version = (const char *)glGetString(GL_VERSION);
        vendor = (const char *)glGetString(GL_VENDOR);
        renderer = (const char *)glGetString(GL_RENDERER);
        if (version)
            sscanf(version, "%d.%d", &major, &minor);
    }
    printf("{\"error-code\":%d,\"error-message\":", (int)error);
    json_string(CGLErrorString(error));
    printf(",\"pixel-formats\":%d,\"context-created\":%s,\"version\":",
           (int)count, error == kCGLNoError && context ? "true" : "false");
    json_string(version);
    fputs(",\"vendor\":", stdout);
    json_string(vendor);
    fputs(",\"renderer\":", stdout);
    json_string(renderer);
    printf(",\"meets-engine-requirement\":%s}",
           core && error == kCGLNoError && context &&
           (major > 3 || (major == 3 && minor >= 3)) ? "true" : "false");

    CGLSetCurrentContext(NULL);
    if (context)
        CGLDestroyContext(context);
    if (format)
        CGLDestroyPixelFormat(format);
}

int main(void)
{
    fputs("{\"legacy\":", stdout);
    probe((CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy, 0);
    fputs(",\"core\":", stdout);
    probe((CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, 1);
    fputs("}\n", stdout);
    return 0;
}
