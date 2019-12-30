#version $GLSL_VERSION_STR
$GLSL_DEFAULT_PRECISION_FLOAT

#pragma vp_entryPoint atmos_vertex_main
#pragma vp_location   vertex_view
#pragma vp_order      0.5

#pragma import_defines(OE_LIGHTING)
#pragma import_defines(OE_NUM_LIGHTS)

uniform mat4 osg_ViewMatrixInverse;   // world camera position in [3].xyz 
uniform mat4 osg_ViewMatrix;          // GL view matrix 
                                      //uniform vec3 atmos_v3LightDir;        // The direction vector to the light source 
uniform vec3 atmos_v3InvWavelength;   // 1 / pow(wavelength,4) for the rgb channels 
uniform float atmos_fOuterRadius;     // Outer atmosphere radius 
uniform float atmos_fOuterRadius2;    // fOuterRadius^2 		
uniform float atmos_fInnerRadius;     // Inner planetary radius 
uniform float atmos_fInnerRadius2;    // fInnerRadius^2 
uniform float atmos_fKrESun;          // Kr * ESun 	
uniform float atmos_fKmESun;          // Km * ESun 		
uniform float atmos_fKr4PI;           // Kr * 4 * PI 	
uniform float atmos_fKm4PI;           // Km * 4 * PI 		
uniform float atmos_fScale;           // 1 / (fOuterRadius - fInnerRadius) 	
uniform float atmos_fScaleDepth;      // The scale depth 
uniform float atmos_fScaleOverScaleDepth;     // fScale / fScaleDepth 	
uniform int atmos_nSamples; 	
uniform float atmos_fSamples; 

out vec3 atmos_color;          // primary sky light color
out vec3 atmos_atten;          // sky light attenuation factor
out vec3 atmos_lightDir;       // light direction in view space

float atmos_fCameraHeight;            // The camera's current height 		
float atmos_fCameraHeight2;           // fCameraHeight^2 

out vec3 atmos_up;             // earth up vector at vertex location (not the normal)
out float atmos_space;         // [0..1]: camera: 0=inner radius (ground); 1.0=outer radius
out vec3 atmos_vert; 

vec3 vp_Normal;             // surface normal (from osgEarth)


                            // Toatl number of lights in the scene
                            //uniform int osg_NumLights;

                            // Parameters of each light:
struct osg_LightSourceParameters 
{   
    vec4 ambient;              // Aclarri   
    vec4 diffuse;              // Dcli   
    vec4 specular;             // Scli   
    vec4 position;             // Ppli   
                               //vec4 halfVector;           // Derived: Hi   
    vec3 spotDirection;        // Sdli   
    float spotExponent;        // Srli   
    float spotCutoff;          // Crli                              
                               // (range: [0.0,90.0], 180.0)   
    float spotCosCutoff;       // Derived: cos(Crli)                 
                               // (range: [1.0,0.0],-1.0)   
    float constantAttenuation; // K0   
    float linearAttenuation;   // K1   
    float quadraticAttenuation;// K2  

    bool enabled;
};  
uniform osg_LightSourceParameters osg_LightSource[OE_NUM_LIGHTS];



float atmos_scale(float fCos) 	
{ 
    float x = 1.0 - fCos; 
    return atmos_fScaleDepth * exp(-0.00287 + x*(0.459 + x*(3.83 + x*(-6.80 + x*5.25)))); 
} 

void atmos_GroundFromSpace(in vec4 vertexVIEW) 
{ 
    // Get the ray from the camera to the vertex and its length (which is the far point of the ray passing through the atmosphere) 
    vec3 v3Pos = vertexVIEW.xyz; 
    vec3 v3Ray = v3Pos; 
    float fFar = length(v3Ray); 
    v3Ray /= fFar; 

    vec4 ec4 = osg_ViewMatrix * vec4(0,0,0,1); 
    vec3 earthCenter = ec4.xyz/ec4.w; 
    vec3 normal = normalize(v3Pos-earthCenter); 
    atmos_up = normal; 

    // Calculate the closest intersection of the ray with the outer atmosphere 
    // (which is the near point of the ray passing through the atmosphere) 
    float B = 2.0 * dot(-earthCenter, v3Ray); 
    float C = atmos_fCameraHeight2 - atmos_fOuterRadius2; 
    float fDet = max(0.0, B*B - 4.0*C); 	
    float fNear = 0.5 * (-B - sqrt(fDet)); 		

    // Calculate the ray's starting position, then calculate its scattering offset 
    vec3 v3Start = v3Ray * fNear; 			
    fFar -= fNear; 
    float fDepth = exp((atmos_fInnerRadius - atmos_fOuterRadius) / atmos_fScaleDepth);
    float fCameraAngle = dot(-v3Ray, normal);  // try max(0, ...) to get rid of yellowing building tops
    float fLightAngle = dot(atmos_lightDir, normal); 
    float fCameraScale = atmos_scale(fCameraAngle); 
    float fLightScale = atmos_scale(fLightAngle); 
    float fCameraOffset = fDepth*fCameraScale; 
    float fTemp = fLightScale * fCameraScale; 		

    // Initialize the scattering loop variables 
    float fSampleLength = fFar / atmos_fSamples; 		
    float fScaledLength = fSampleLength * atmos_fScale; 					
    vec3 v3SampleRay = v3Ray * fSampleLength; 	
    vec3 v3SamplePoint = v3Start + v3SampleRay * 0.5; 	

    // Now loop through the sample rays 
    vec3 v3FrontColor = vec3(0.0, 0.0, 0.0); 
    vec3 v3Attenuate = vec3(1,0,0); 

    for(int i=0; i<atmos_nSamples; ++i) 
    {         
        float fHeight = length(v3SamplePoint-earthCenter); 			
        float fDepth = exp(atmos_fScaleOverScaleDepth * (atmos_fInnerRadius - fHeight)); 
        float fScatter = fDepth*fTemp - fCameraOffset; 
        v3Attenuate = exp(-fScatter * (atmos_v3InvWavelength * atmos_fKr4PI + atmos_fKm4PI)); 	
        v3FrontColor += v3Attenuate * (fDepth * fScaledLength); 					
        v3SamplePoint += v3SampleRay; 		
    } 	

    atmos_color = v3FrontColor * (atmos_v3InvWavelength * atmos_fKrESun + atmos_fKmESun); 
    atmos_atten = v3Attenuate; 
} 		

void atmos_GroundFromAtmosphere(in vec4 vertexVIEW) 		
{ 
    // Get the ray from the camera to the vertex and its length (which is the far point of the ray passing through the atmosphere) 
    vec3 v3Pos = vertexVIEW.xyz / vertexVIEW.w; 
    vec3 v3Ray = v3Pos; 
    float fFar = length(v3Ray); 
    v3Ray /= fFar; 

    vec4 ec4 = osg_ViewMatrix * vec4(0,0,0,1); 
    vec3 earthCenter = ec4.xyz/ec4.w; 
    vec3 normal = normalize(v3Pos-earthCenter); 
    atmos_up = normal; 

    // Calculate the ray's starting position, then calculate its scattering offset 
    float fDepth = exp((atmos_fInnerRadius - atmos_fCameraHeight) / atmos_fScaleDepth);
    float fCameraAngle = max(0.0, dot(-v3Ray, normal)); 
    float fLightAngle = dot(atmos_lightDir, normal); 
    float fCameraScale = atmos_scale(fCameraAngle); 
    float fLightScale = atmos_scale(fLightAngle); 
    float fCameraOffset = fDepth*fCameraScale; 
    float fTemp = fLightScale * fCameraScale; 

    // Initialize the scattering loop variables 	
    float fSampleLength = fFar / atmos_fSamples; 		
    float fScaledLength = fSampleLength * atmos_fScale; 					
    vec3 v3SampleRay = v3Ray * fSampleLength; 	
    vec3 v3SamplePoint = v3SampleRay * 0.5; 	

    // Now loop through the sample rays 
    vec3 v3FrontColor = vec3(0.0, 0.0, 0.0); 
    vec3 v3Attenuate;   
    for(int i=0; i<atmos_nSamples; i++) 		
    { 
        float fHeight = length(v3SamplePoint-earthCenter); 			
        float fDepth = exp(atmos_fScaleOverScaleDepth * (atmos_fInnerRadius - fHeight)); 
        float fScatter = fDepth*fTemp - fCameraOffset; 
        v3Attenuate = exp(-fScatter * (atmos_v3InvWavelength * atmos_fKr4PI + atmos_fKm4PI)); 	
        v3FrontColor += v3Attenuate * (fDepth * fScaledLength); 					
        v3SamplePoint += v3SampleRay; 		
    } 		

    atmos_color = v3FrontColor * (atmos_v3InvWavelength * atmos_fKrESun + atmos_fKmESun); 			
    atmos_atten = v3Attenuate; 
} 

void atmos_vertex_main(inout vec4 vertexVIEW) 
{
#ifndef OE_LIGHTING
    return;
#endif

    atmos_fCameraHeight = length(osg_ViewMatrixInverse[3].xyz); 
    atmos_fCameraHeight2 = atmos_fCameraHeight*atmos_fCameraHeight; 
    atmos_lightDir = normalize(osg_LightSource[0].position.xyz);  // view space
    atmos_vert = vertexVIEW.xyz; 

    atmos_space = max(0.0, (atmos_fCameraHeight-atmos_fInnerRadius)/(atmos_fOuterRadius-atmos_fInnerRadius));

    if(atmos_fCameraHeight >= atmos_fOuterRadius) 
    { 
        atmos_GroundFromSpace(vertexVIEW); 
    } 
    else 
    { 
        atmos_GroundFromAtmosphere(vertexVIEW); 
    } 
}


[break]


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
    oe_ambientOcclusion = 0.1;
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

// PBR lighting model.
// https://learnopengl.com/PBR/Theory
// https://gist.github.com/FrankRicharrd/2fc71b1460a9089edd69c4ac1814dc95

const float PI = 3.14159265359;

float oe_DistributionGGX(vec3 N, vec3 H, float roughness)
{
    float a = roughness*roughness;
    float a2 = a*a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;
    float nom   = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return nom / max(denom, 0.001);
}

float oe_GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;
    float nom   = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return nom / denom;
}

float oe_GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = oe_GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = oe_GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

vec3 oe_FresnelSchlick(float cosTheta, vec3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

// MAIN ENTRY POINT
void atmos_fragment_main(inout vec4 color)
{
#ifndef OE_LIGHTING
    return;
#endif

    vec3 metallic = vec3(oe_metallic);
    vec3 albedo = color.rgb;

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
        vec3 L = normalize(osg_LightSource[i].position.xyz);
        vec3 H = normalize(V + L);
        //float distance = length(osg_LightSource[i].position.xyz);
        //float attenuation = 1.0 / (distance * distance);
        vec3 radiance = osg_LightSource[i].diffuse.rgb * osg_LightSource[i].constantAttenuation;

        // Cook-Torrance BRDF
        float NDF = oe_DistributionGGX(N, H, oe_roughness);   
        float G = oe_GeometrySmith(N, V, L, oe_roughness);      
        vec3 F = oe_FresnelSchlick(clamp(dot(H, V), 0.0, 1.0), F0);

        vec3 nominator    = NDF * G * F; 
        float denominator = 4 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
        vec3 specular = nominator / max(denominator, 0.001); // prevent div/0

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
        // note that we already multiplied the BRDF by the Fresnel (kS) so we won't multiply by kS again
        Lo += (kD * albedo / PI + specular) * radiance * NdotL;
    }   

    // ambient lighting (future: apply IBL).
    vec3 ambient = vec3(0.03) * albedo * oe_ambientOcclusion;

    vec3 result = ambient + Lo;

    // HDR tonemapping
    result = result / (result + vec3(1.0));

    // gamma correct
    result = pow(result, vec3(1.0/2.2));

    // exposure
    result = 1.0 - exp(-oe_sky_exposure * result);

    color.rgb = clamp(result, 0, 1);
}
