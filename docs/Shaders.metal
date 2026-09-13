#include <CoreImage/CoreImage.h>

extern "C" {
    namespace coreimage {
        float2 cylindrical(float width, float angle, float bindingOnLeft, destination dest) {
            float2 p = dest.coord();
            float u = clamp(p.x / width, 0.0f, 1.0f);
            float v = mix(u, 1.0f - u, bindingOnLeft);
            float mapped = sin(v * angle) / sin(angle);
            mapped = mix(mapped, 1.0f - mapped, bindingOnLeft);
            return float2(mapped * width, p.y);
        }
    }
}
