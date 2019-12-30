#version $GLSL_VERSION_STR
$GLSL_DEFAULT_PRECISION_FLOAT

#pragma vp_entryPoint atmos_fragment_init
#pragma vp_location   fragment_coloring
#pragma vp_order      first

// stage globals
float oe_metallic;
float oe_roughness;
float oe_ambientOcclusion;

void atmos_fragment_init(inout vec4 unused)
{
    oe_metallic = 0.1;
    oe_roughness = 0.75;
    oe_ambientOcclusion = 0.2;
}

[break]


#version $GLSL_VERSION_STR
$GLSL_DEFAULT_PRECISION_FLOAT

#pragma vp_entryPoint atmos_fragment_main
#pragma vp_location   fragment_lighting
#pragma vp_order      0.8

#pragma import_defines(OE_LIGHTING)
#pragma import_defines(OE_NUM_LIGHTS)

uniform float oe_sky_exposure;           // HDR scene exposure (ground level)
uniform float oe_sky_ambientBoostFactor; // ambient sunlight booster for daytime

in vec3 atmos_lightDir;    // light direction (view coords)
in vec3 atmos_color;       // atmospheric lighting color
in vec3 atmos_atten;       // atmospheric lighting attenuation factor
in vec3 atmos_up;          // earth up vector at fragment (in view coords)
in float atmos_space;      // camera altitude (0=ground, 1=atmos outer radius)
in vec3 atmos_vert; 
        
vec3 vp_Normal;          // surface normal (from osgEarth)

// stage globals
float oe_metallic;
float oe_roughness;
float oe_ambientOcclusion;

// Parameters of each light:
struct osg_LightSourceParameters 
{   
   vec4 ambient;
   vec4 diffuse;
   vec4 specular;
   vec4 position;
   vec3 spotDirection;
   float spotExponent;
   float spotCutoff;
   float spotCosCutoff;
   float constantAttenuation;
   float linearAttenuation;
   float quadraticAttenuation;

   bool enabled;
};  
uniform osg_LightSourceParameters osg_LightSource[OE_NUM_LIGHTS];

// Surface material:
struct osg_MaterialParameters  
{   
   vec4 emission;    // Ecm   
   vec4 ambient;     // Acm   
   vec4 diffuse;     // Dcm   
   vec4 specular;    // Scm   
   float shininess;  // Srm  
};  
uniform osg_MaterialParameters osg_FrontMaterial; 

#define USE_PBR
#ifdef USE_PBR
const float PI = 3.14159265359;

float DistributionGGX(vec3 N, vec3 H, float roughness)
{
    float a = roughness*roughness;
    float a2 = a*a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;

    float nom   = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return nom / max(denom, 0.001); // prevent divide by zero for roughness=0.0 and NdotH=1.0
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;

    float nom   = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return nom / denom;
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

void atmos_fragment_main(inout vec4 color)
{
#ifndef OE_LIGHTING
    return;
#endif

    vec3 metallic = vec3(oe_metallic);
    vec3 albedo = color.rgb;
    float roughness = oe_roughness;
    float ao = oe_ambientOcclusion;

    vec3 N = normalize(vp_Normal);
    vec3 V = -normalize(atmos_vert);

    // calculate reflectance at normal incidence; if dia-electric (like plastic) use F0 
    // of 0.04 and if it's a metal, use the albedo color as F0 (metallic workflow)    
    vec3 F0 = vec3(0.04); 
    F0 = mix(F0, albedo, metallic);

    // reflectance equation
    vec3 Lo = vec3(0.0);
    for(int i = 0; i < OE_NUM_LIGHTS; ++i) 
    {
        // calculate per-light radiance
        vec3 L = normalize(osg_LightSource[i].position.xyz); // - WorldPos);
        vec3 H = normalize(V + L);
        float distance = length(osg_LightSource[i].position.xyz); // - WorldPos);
        float attenuation = 1.0 / (distance * distance);
        vec3 radiance = osg_LightSource[i].diffuse.rgb * osg_LightSource[i].constantAttenuation; //attenuation;

        // Cook-Torrance BRDF
        float NDF = DistributionGGX(N, H, roughness);   
        float G   = GeometrySmith(N, V, L, roughness);      
        vec3 F    = fresnelSchlick(clamp(dot(H, V), 0.0, 1.0), F0);

        vec3 nominator    = NDF * G * F; 
        float denominator = 4 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
        vec3 specular = nominator / max(denominator, 0.001); // prevent divide by zero for NdotV=0.0 or NdotL=0.0

                                                             // kS is equal to Fresnel
        vec3 kS = F;
        // for energy conservation, the diffuse and specular light can't
        // be above 1.0 (unless the surface emits light); to preserve this
        // relationship the diffuse component (kD) should equal 1.0 - kS.
        vec3 kD = vec3(1.0) - kS;
        // multiply kD by the inverse metalness such that only non-metals 
        // have diffuse lighting, or a linear blend if partly metal (pure metals
        // have no diffuse light).
        kD *= 1.0 - metallic;	  

        // scale light by NdotL
        float NdotL = max(dot(N, L), 0.0);        

        // add to outgoing radiance Lo
        Lo += (kD * albedo / PI + specular) * radiance * NdotL;  // note that we already multiplied the BRDF by the Fresnel (kS) so we won't multiply by kS again
    }   

    // ambient lighting (note that the next IBL tutorial will replace 
    // this ambient lighting with environment lighting).
    vec3 ambient = vec3(0.03) * albedo * ao;

    vec3 result = ambient + Lo;

    // HDR tonemapping
    result = result / (result + vec3(1.0));

    // gamma correct
    result = pow(result, vec3(1.0/2.2));

    // exposure
    result = 1.0 - exp(-oe_sky_exposure * result);

    color.rgb = clamp(result, 0, 1);
}

#else // USE_PBR

void atmos_fragment_main(inout vec4 color) 
{ 
#ifndef OE_LIGHTING
    return;
#endif

    // See:
    // https://en.wikipedia.org/wiki/Phong_reflection_model
    // https://www.opengl.org/sdk/docs/tutorials/ClockworkCoders/lighting.php
    // https://en.wikibooks.org/wiki/GLSL_Programming/GLUT/Multiple_Lights
    // https://en.wikibooks.org/wiki/GLSL_Programming/GLUT/Specular_Highlights

    // normal vector at vertex
    vec3 N = normalize(vp_Normal);

    float shine = clamp(osg_FrontMaterial.shininess, 1.0, 128.0); 
    vec4 surfaceSpecularity = osg_FrontMaterial.specular;
    
    // up vector at vertex
    vec3 U = normalize(atmos_up);

    // Accumulate the lighting for each component separately.
    vec3 totalDiffuse = vec3(0.0);
    vec3 totalAmbient = vec3(0.0);
    vec3 totalSpecular = vec3(0.0);

    int numLights = OE_NUM_LIGHTS;

    for (int i=0; i<numLights; ++i)
    {
        if (osg_LightSource[i].enabled)
        {
            float attenuation = 1.0;

            // L is the normalized camera-to-light vector.
            vec3 L = normalize(osg_LightSource[i].position.xyz);

            // V is the normalized vertex-to-camera vector.
            vec3 V = -normalize(atmos_vert);

            // point or spot light:
            if (osg_LightSource[i].position.w != 0.0)
            {
                // VLu is the unnormalized vertex-to-light vector
                vec3 Lu = osg_LightSource[i].position.xyz - atmos_vert;

                // calculate attenuation:
                float distance = length(Lu);
                attenuation = 1.0 / (
                    osg_LightSource[i].constantAttenuation +
                    osg_LightSource[i].linearAttenuation * distance +
                    osg_LightSource[i].quadraticAttenuation * distance * distance);

                // for a spot light, the attenuation help form the cone:
                if (osg_LightSource[i].spotCutoff <= 90.0)
                {
                    vec3 D = normalize(osg_LightSource[i].spotDirection);
                    float clampedCos = max(0.0, dot(-L,D));
                    attenuation = clampedCos < osg_LightSource[i].spotCosCutoff ?
                        0.0 :
                        attenuation * pow(clampedCos, osg_LightSource[i].spotExponent);
                }
            }

            // a term indicating whether it's daytime for light 0 (the sun).
            float dayTerm = i==0? dot(U,L) : 1.0;

            // This term boosts the ambient lighting for the sun (light 0) when it's daytime.
            // TODO: make the boostFactor a uniform?
            float ambientBoost = i==0? 1.0 + oe_sky_ambientBoostFactor*clamp(2.0*(dayTerm-0.5), 0.0, 1.0) : 1.0;

            vec3 ambientReflection =
                attenuation
                * osg_LightSource[i].ambient.rgb
                * ambientBoost;

            float NdotL = max(dot(N,L), 0.0);

            // this term, applied to light 0 (the sun), attenuates the diffuse light
            // during the nighttime, so that geometry doesn't get lit based on its
            // normals during the night.
            float diffuseAttenuation = clamp(dayTerm+0.35, 0.0, 1.0);
            
            vec3 diffuseReflection =
                attenuation
                * diffuseAttenuation
                * osg_LightSource[i].diffuse.rgb
                * NdotL;
                
            vec3 specularReflection = vec3(0.0);
            if (NdotL > 0.0)
            {
                // prevent a sharp edge where NdotL becomes positive
                // by fading in the spec between (0.0 and 0.1)
                float specAttenuation = clamp(NdotL*10.0, 0.0, 1.0);

                vec3 H = reflect(-L,N);
                float HdotV = max(dot(H,V), 0.0); 

                specularReflection =
                      specAttenuation
                    * attenuation
                    * osg_LightSource[i].specular.rgb
                    * surfaceSpecularity.rgb
                    * pow(HdotV, shine);
            }

            totalDiffuse += diffuseReflection;
            totalAmbient += ambientReflection;
            totalSpecular += specularReflection;
        }
    }
    
    // add the atmosphere color, and incorpoate the lights.
    color.rgb += atmos_color;

    vec3 lightColor =
        osg_FrontMaterial.emission.rgb +
        totalDiffuse * osg_FrontMaterial.diffuse.rgb +
        totalAmbient * osg_FrontMaterial.ambient.rgb;

    color.rgb =
        color.rgb * lightColor +
        totalSpecular; // * osg_FrontMaterial.specular.rgb;
    
    // Simulate HDR by applying an exposure factor (1.0 is none, 2-3 are reasonable)
    color.rgb = 1.0 - exp(-oe_sky_exposure * color.rgb);
}

#endif // USE_PBR