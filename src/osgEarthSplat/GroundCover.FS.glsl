#version $GLSL_VERSION_STR
#pragma vp_name       Land cover billboard texture application
#pragma vp_entryPoint oe_GroundCover_fragment
#pragma vp_location   fragment_coloring

#pragma import_defines(OE_GROUNDCOVER_HAS_MULTISAMPLES)
#pragma import_defines(OE_IS_SHADOW_CAMERA)

uniform sampler2DArray oe_GroundCover_billboardTex;
uniform float oe_GroundCover_exposure;

in vec2 oe_GroundCover_texCoord;

in vec3 oe_normalMapBinormal;

flat in float oe_GroundCover_atlasIndex; // from GroundCover.GS.glsl
flat in float oe_GroundCover_atlasMaterialIndex; // "

// stage globals
float oe_roughness;
float oe_ambientOcclusion;

vec3 vp_Normal;

vec3 decodeNormal(in vec4 enc)
{
    vec3 n = vec3(enc.xy*2-1, 1);
    n.z = sqrt(1-dot(n.xy, n.xy));
    return n;
}
#define decodeRoughness(X) (1.0-(X).z)
#define decodeAO(X) ((X).w)

void oe_GroundCover_fragment(inout vec4 color)
{
    if (oe_GroundCover_atlasIndex < 0.0)
        discard;

    // modulate the texture
    color = texture(oe_GroundCover_billboardTex, vec3(oe_GroundCover_texCoord, oe_GroundCover_atlasIndex)) * color;
    color.rgb *= oe_GroundCover_exposure;

    if (oe_GroundCover_atlasMaterialIndex >= 0.0)
    {
        vec4 material = texture(oe_GroundCover_billboardTex, vec3(oe_GroundCover_texCoord, oe_GroundCover_atlasMaterialIndex));
        vec3 normal = decodeNormal(material);
        oe_roughness = decodeRoughness(material);
        oe_ambientOcclusion = decodeAO(material);

        // xform the material's normal to the plane of the original normal
        vec3 tangent = normalize(cross(oe_normalMapBinormal, vp_Normal));
        mat3 TBN = mat3(tangent, oe_normalMapBinormal, vp_Normal);
        vp_Normal = normalize(TBN*normalize(normal));
    }
    else
    {
        oe_roughness = 1.0;
        oe_ambientOcclusion = 0.5;
    }
    
    // if multisampling is off, use alpha-discard.
#if !defined(OE_GROUNDCOVER_HAS_MULTISAMPLES) || defined(OE_IS_SHADOW_CAMERA)
    if (color.a < 0.15)
        discard;
#endif
}
