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
