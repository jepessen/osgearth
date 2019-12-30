#version 330
#pragma vp_entryPoint oe_Splat_model
#pragma vp_location vertex_model
#pragma import_defines(OE_LANDCOVER_TEX_MATRIX)

// from SDK:
vec2 oe_terrain_scaleCoordsToRefLOD(in vec2, in float);
float oe_terrain_getElevation();
vec4 oe_terrain_getNormalAndCurvature();

uniform mat4 OE_LANDCOVER_TEX_MATRIX;

out vec2 oe_Splat_noiseTC;
out vec2 oe_Splat_landCoverTC;
out vec2 oe_Splat_primTC;
out vec3 oe_Splat_terrain;
vec4 oe_layer_tilec;

#define OE_SPLAT_NOISE_LOD 14
#define OE_SPLAT_PRIMITIVE_LOD 16

void oe_Splat_model(inout vec4 vertex_model)
{
    oe_Splat_noiseTC = oe_terrain_scaleCoordsToRefLOD(oe_layer_tilec.st, OE_SPLAT_NOISE_LOD);

    oe_Splat_landCoverTC = (OE_LANDCOVER_TEX_MATRIX * oe_layer_tilec).st;
    
    oe_Splat_primTC = oe_terrain_scaleCoordsToRefLOD(oe_layer_tilec.st, OE_SPLAT_PRIMITIVE_LOD);

    oe_Splat_terrain[0] = oe_terrain_getElevation();
    vec4 n_and_c = oe_terrain_getNormalAndCurvature();
    vec3 normalTangent = normalize(n_and_c.xyz*2.0-1.0);
    oe_Splat_terrain[1] = 2.0*(1.0 - clamp(dot(normalTangent, gl_Normal), 0, 1));

    oe_Splat_terrain[2] = n_and_c.a;
}


[break]


#version 330
#pragma vp_entryPoint oe_Splat_fs
#pragma vp_location fragment_coloring
#pragma import_defines(OE_LANDCOVER_TEX)
#pragma import_defines(OE_SPLAT_ATLAS_TEX)
#pragma import_defines(OE_SPLAT_NOISE_TEX)

// from SDK:
vec2 oe_terrain_scaleCoordsToRefLOD(in vec2, in float);
float oe_terrain_getElevation();
vec4 oe_terrain_getNormalAndCurvature();

#define NOISE_SMOOTH   0
#define NOISE_RANDOM   1
#define NOISE_RANDOM_2 2
#define NOISE_CLUMPY   3

// stage globals
vec4 oe_layer_tilec;
vec3 oe_UpVectorView;
vec3 vp_Normal;

// stage lighting globals, set here
float oe_roughness;
float oe_ambientOcclusion;

// texture array containing RGBH/material data
uniform sampler2DArray OE_SPLAT_ATLAS_TEX;

uniform sampler2D OE_LANDCOVER_TEX;

// tiled noise function
uniform sampler2D OE_SPLAT_NOISE_TEX;

// from vertex shader
in vec2 oe_Splat_noiseTC;
in vec2 oe_Splat_landCoverTC;
in vec2 oe_Splat_primTC;
in vec3 oe_Splat_terrain; // (elevation, slope, curvature)

in vec3 oe_normalMapBinormal;

// generated function to resolve the data at a pixel
bool oe_Splat_resolve(in int code, in int lod, in float elevation, in float slope, in float curvature, in float noise, out float d[5]);

vec4 hmix(in vec4 tex1, in vec4 tex2, in float blend)
{
    float a1 = 1.0-blend, a2 = blend;

    // span over which to sample and blend heights for blending
    const float depth = 0.05;

    vec4 r;
    float ma = max(tex1.a+a1, tex2.a+a2)-depth;
    float b1 = max(tex1.a+a1-ma, 0);
    float b2 = max(tex2.a+a2-ma, 0);
    r.rgba = (tex1.rgba*b1+tex2.rgba*b2)/(b1+b2);
    return r;
}

vec3 decodeNormal(in vec4 enc)
{
    vec3 n = vec3(enc.xy*2-1, 1);
    n.z = sqrt(1-dot(n.xy, n.xy));
    return n;
}

#define decodeRoughness(X) (1.0-(X).z)

#define decodeAO(X) ((X).w)

void oe_Splat_fs(inout vec4 color)
{    
    // Sample the noise function
    vec4 noise = texture(OE_SPLAT_NOISE_TEX, oe_Splat_noiseTC);
    
    // Look up the class data
    int code = int(texture(OE_LANDCOVER_TEX, oe_Splat_landCoverTC).r);

    // data = (index0, index1, blend1, index2, blend2)
    float data[5];

    bool good = oe_Splat_resolve(
        code,
        int(oe_layer_tilec.z), // lod
        oe_Splat_terrain[0],
        oe_Splat_terrain[1],
        oe_Splat_terrain[2],
        noise[NOISE_SMOOTH],
        data);

    if (good)
    {
        // accumulate the result.
        // start with simple blending; later we'll add complex blending
        vec4 outRGBH;
        vec3 outNormal;
        vec4 rgbh;
        vec4 material;

        // base layer:
        outRGBH = texture(OE_SPLAT_ATLAS_TEX, vec3(oe_Splat_primTC, data[0]));
        material = texture(OE_SPLAT_ATLAS_TEX, vec3(oe_Splat_primTC, data[0]+1));
        outNormal = decodeNormal(material);
        oe_roughness = decodeRoughness(material);
        oe_ambientOcclusion = decodeAO(material);
    
        // primary layer:
        if (data[1] >= 0)
        {
            rgbh = texture(OE_SPLAT_ATLAS_TEX, vec3(oe_Splat_primTC, data[1]));
            outRGBH = hmix(outRGBH, rgbh, data[2]);
            material = texture(OE_SPLAT_ATLAS_TEX, vec3(oe_Splat_primTC, data[1]+1));
            outNormal = mix(outNormal, decodeNormal(material), data[2]);
            oe_roughness = mix(oe_roughness, decodeRoughness(material), data[2]);
            oe_ambientOcclusion = mix(oe_ambientOcclusion, decodeAO(material), data[2]);

            // secondary layer:
            if (data[3] >= 0)
            {
                // secondary (detail) layer:
                rgbh = texture(OE_SPLAT_ATLAS_TEX, vec3(oe_Splat_primTC, data[3]));
                outRGBH = hmix(outRGBH, rgbh, data[4]);

                material = texture(OE_SPLAT_ATLAS_TEX, vec3(oe_Splat_primTC, data[3]+1));
                outNormal = mix(outNormal, decodeNormal(material), data[4]);
                oe_roughness = mix(oe_roughness, decodeRoughness(material), data[4]);
                oe_ambientOcclusion = mix(oe_ambientOcclusion, decodeAO(material), data[4]);
            }
        }
    
        color = vec4(outRGBH.rgb, 1.0);

        // xform the material's normal to the plane of the original normal
        vec3 tangent = normalize(cross(oe_normalMapBinormal, vp_Normal));
        mat3 TBN = mat3(tangent, oe_normalMapBinormal, vp_Normal);
        vp_Normal = normalize(TBN*normalize(outNormal));
    }
    else
    {
        color = vec4(1,0,0,1);
        oe_roughness = 1.0;
        oe_ambientOcclusion = 1.0;
    }

    // finally, use noise to vary the color
    // todo...
}
