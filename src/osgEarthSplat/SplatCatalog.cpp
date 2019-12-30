/* -*-c++-*- */
/* osgEarth - Geospatial SDK for OpenSceneGraph
 * Copyright 2018 Pelican Mapping
 * http://osgearth.org
 *
 * osgEarth is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>
 */
#include "SplatCatalog"
#include <osgEarth/Config>
#include <osgEarth/ImageUtils>
#include <osgEarth/XmlUtils>
#include <osgEarth/Containers>
#include <osgEarth/URI>
#include <osg/Texture2DArray>

using namespace osgEarth;
using namespace osgEarth::Splat;

#define LC "[SplatCatalog] "

#define SPLAT_CATALOG_CURRENT_VERSION 1


//............................................................................

SplatDetailData::SplatDetailData() :
_textureIndex( -1 )
{
    //nop
}

SplatDetailData::SplatDetailData(const Config& conf) :
_textureIndex( -1 )
{
    conf.get("image",      _imageURI);
    conf.get("brightness", _brightness);
    conf.get("contrast",   _contrast);
    conf.get("threshold",  _threshold);
    conf.get("slope",      _slope);
}

Config
SplatDetailData::getConfig() const
{
    Config conf;
    conf.set("image",      _imageURI);
    conf.set("brightness", _brightness);
    conf.set("contrast",   _contrast);
    conf.set("threshold",  _threshold);
    conf.set("slope",      _slope);
    return conf;
}

//............................................................................

SplatPrimitiveLOD::SplatPrimitiveLOD() :
    _textureAtlasIndex(-1),
    _maxLevel(INT_MAX)
{
    //nop
}

SplatPrimitiveLOD::SplatPrimitiveLOD(const Config& conf) :
    _textureAtlasIndex(-1)
{
    conf.get("max_level", _maxLevel);
    conf.get("diffuse", _diffuseURI);
    conf.get("height", _heightURI);
    conf.get("normal", _normalURI);
    conf.get("smoothness", _smoothURI);
    conf.get("roughness", _roughURI);
    conf.get("ao", _aoURI);
}

Config
SplatPrimitiveLOD::getConfig() const
{
    Config conf;
    conf.set("max_level", _maxLevel);
    conf.set("diffuse", _diffuseURI);
    conf.set("height", _heightURI);
    conf.set("normal", _normalURI);
    conf.set("smoothness", _smoothURI);
    conf.set("roughness", _roughURI);
    conf.set("ao", _aoURI);
    return conf;
}

//............................................................................

const SplatPrimitiveLOD*
SplatPrimitiveLODVector::getLOD(int lod) const
{
    for(const_iterator i = begin(); i != end(); ++i)
    {
        if (i->_maxLevel.get() > lod)
            return &(*i);
    }
    return !empty()? &(*rbegin()) : NULL;
}

//............................................................................

SplatPrimitive::SplatPrimitive(const Config& conf)
{
    conf.get("name", _name);
    ConfigSet lods = conf.children("lod");
    for(ConfigSet::const_iterator lod = lods.begin();
        lod != lods.end();
        ++lod)
    {
        _lods.push_back(SplatPrimitiveLOD(*lod));
    }
}

Config
SplatPrimitive::getConfig() const
{
    //TODO
    return Config();
}

//............................................................................

SplatClassLayer::SplatClassLayer(const Config& conf)
{
    conf.get("primitive", _primitiveName);
    _glslExpression = conf.value();
}

//............................................................................

SplatClass::SplatClass()
{
    //nop
}

SplatClass::SplatClass(const Config& conf)
{
    _name = conf.value("name");
    const ConfigSet& layers = conf.child("layers").children();
    for(ConfigSet::const_iterator i = layers.begin();
        i != layers.end();
        ++i)
    {
        _layers.push_back(SplatClassLayer(*i));
    }
}

Config
SplatClass::getConfig() const
{
    //TODO
    return Config();
}

//............................................................................

SplatCatalog::SplatCatalog()
{
    _version = SPLAT_CATALOG_CURRENT_VERSION;
}

void
SplatCatalog::fromConfig(const Config& conf)
{
    conf.get("version",     _version);
    conf.get("name",        _name);
    conf.get("description", _description);

    const ConfigSet& primitives = conf.child("primitives").children();
    for(ConfigSet::const_iterator i = primitives.begin();
        i != primitives.end();
        ++i)
    {
        _primitives[i->value("name")] = SplatPrimitive(*i);
    }

    Config classesConf = conf.child("classes");
    if ( !classesConf.empty() )
    {
        for(ConfigSet::const_iterator i = classesConf.children().begin(); i != classesConf.children().end(); ++i)
        {
            SplatClass sclass(*i);
            if ( !sclass._name.empty() )
            {
                _classes[sclass._name] = sclass;
            }
        }
    }
}

Config
SplatCatalog::getConfig() const
{
    Config conf;
    conf.set("version",     _version);
    conf.set("name",        _name);
    conf.set("description", _description);
    
    Config classes("classes");
    {
        for(SplatClassMap::const_iterator i = _classes.begin(); i != _classes.end(); ++i)
        {
            classes.add( "class", i->second.getConfig() );
        }
    }    
    conf.set( classes );

    return conf;
}

const SplatClass*
SplatCatalog::getClass(const std::string& name) const
{
    SplatClassMap::const_iterator i = _classes.find(name);
    return i != _classes.end()? &i->second : NULL;
}

const SplatPrimitive*
SplatCatalog::getPrimitive(const std::string& name) const
{
    SplatPrimitiveMap::const_iterator i = _primitives.find(name);
    return i != _primitives.end()? &i->second : NULL;
}

namespace
{
    osg::Image* loadImage(const URI& uri, const osgDB::Options* dbOptions, osg::Image* firstImage)
    {
        // try to load the image:
        ReadResult result = uri.readImage(dbOptions);
        if ( result.succeeded() )
        {
            // if this is the first image loaded, remember it so we can ensure that
            // all images are copatible.
            if ( firstImage == 0L )
            {
                firstImage = result.getImage();

                // require rgba8 so we can encode the heightmap in the alpha channel
                if (firstImage->getPixelFormat() != GL_RGBA)
                {
                    osg::ref_ptr<osg::Image> rgba = ImageUtils::convertToRGBA8(firstImage);
                    firstImage = rgba.get();
                    return rgba.release();
                }
            }
            else
            {
                // ensure compatibility, a requirement for texture arrays.
                // In the future perhaps we can resize/convert instead.
                if ( !ImageUtils::textureArrayCompatible(result.getImage(), firstImage) )
                {
                    osg::ref_ptr<osg::Image> conv = ImageUtils::convert(result.getImage(), firstImage->getPixelFormat(), firstImage->getDataType());

                    if ( conv->s() != firstImage->s() || conv->t() != firstImage->t() )
                    {
                        osg::ref_ptr<osg::Image> conv2;
                        if ( ImageUtils::resizeImage(conv.get(), firstImage->s(), firstImage->t(), conv2) )
                        {
                            conv = conv2.get();
                        }
                    }

                    if ( ImageUtils::textureArrayCompatible(conv.get(), firstImage) )
                    {
                        conv->setInternalTextureFormat( firstImage->getInternalTextureFormat() );
                        return conv.release();
                    }
                    else
                    {
                        OE_WARN << LC << "Image " << uri.base()
                            << " was found, but cannot be used because it is not compatible with "
                            << "other splat images (same dimensions, pixel format, etc.)\n";
                        return 0L;
                    }
                }
            }
        }
        else
        {
            OE_WARN << LC
                << "Image in the splat catalog failed to load: "
                << uri.full() << "; message = " << result.getResultCodeString()
                << std::endl;
        }

        return result.releaseImage();
    }
}

bool
SplatCatalog::createSplatTextureDef(const osgDB::Options* dbOptions,
                                    SplatTextureDef&      out)
{
    // Reset all texture atlas indices to default
    unsigned atlasIndex = 0;
    unsigned s = 0, t = 0;
    std::vector< osg::ref_ptr<osg::Image> > diffuseImages;
    osg::Image* firstImage = NULL;

    for(SplatPrimitiveMap::iterator i = _primitives.begin();
        i != _primitives.end();
        ++i)
    {
        SplatPrimitive& primitive = i->second;
        for(SplatPrimitiveLODVector::iterator lod = primitive._lods.begin();
            lod != primitive._lods.end();
            ++lod)
        {
            lod->_textureAtlasIndex = -1;

            if (lod->_diffuseURI.isSet())
            {
                osg::ref_ptr<osg::Image> diffuse = loadImage(lod->_diffuseURI.get(), dbOptions, firstImage);
                if (diffuse.valid())
                {
                    if (firstImage == NULL)
                        firstImage = diffuse.get();

                    // Encode the height value in the alpha channel.
                    osg::ref_ptr<osg::Image> heightmap = loadImage(lod->_heightURI.get(), dbOptions, firstImage);
                    ImageUtils::PixelReader readHeight(heightmap.get());
                    ImageUtils::PixelReader readRGBH(diffuse.get());
                    ImageUtils::PixelWriter writeRGBH(diffuse.get());
                    osg::Vec4 rgbh, height;

                    for(int t=0; t<readRGBH.t(); ++t)
                    {
                        for(int s=0; s<readRGBH.s(); ++s)
                        {
                            readRGBH(rgbh, s, t);
                            if (heightmap.valid())
                            {
                                readHeight(height, s, t);
                                rgbh.a() = height.r();
                            }
                            else
                            {
                                rgbh.a() = 0.0;
                            }
                            writeRGBH(rgbh, s, t);
                        }
                    }

                    lod->_textureAtlasIndex = diffuseImages.size();
                    diffuseImages.push_back(diffuse.get());

                    osg::ref_ptr<osg::Image> material;
                    material = new osg::Image();
                    material->allocateImage(firstImage->s(), firstImage->t(), 1, firstImage->getPixelFormat(), firstImage->getDataType());
                    material->setInternalTextureFormat(GL_RGBA8);

                    osg::ref_ptr<osg::Image> normal = loadImage(lod->_normalURI.get(), dbOptions, firstImage);
                    osg::ref_ptr<osg::Image> smooth = loadImage(lod->_smoothURI.get(), dbOptions, firstImage);
                    osg::ref_ptr<osg::Image> rough = loadImage(lod->_roughURI.get(), dbOptions, firstImage);
                    osg::ref_ptr<osg::Image> ao = loadImage(lod->_aoURI.get(), dbOptions, firstImage);

                    ImageUtils::PixelReader readNormal(normal.get());
                    ImageUtils::PixelReader readSmooth(smooth.get());
                    ImageUtils::PixelReader readRough(rough.get());
                    ImageUtils::PixelReader readAO(ao.get());

                    ImageUtils::PixelWriter writeMaterial(material.get());

                    osg::Vec4 input, output;
                    for(int t=0; t<material->t(); ++t)
                    {
                        for(int s=0; s<material->s(); ++s)
                        {
                            // (normal X/2+1, normal Y/2+1, roughness, AO)
                            output.set(0.5, 0.5, 0.25, 0.20);

                            if (normal.valid())
                            {
                                readNormal(input, s, t);
                                output.x() = input.x(), output.y() = input.y();
                            }

                            if (smooth.valid())
                            {
                                readSmooth(input, s, t);
                                output.z() = input.r();
                            }
                            else if (rough.valid())
                            {
                                readRough(input, s, t);
                                output.z() = 1.0-input.r();
                            }
                            // custom default smoothness for water
                            else if (i->first == "water") output.z() = 0.65;

                            if (ao.valid())
                            {
                                readAO(input, s, t);
                                output.w() = input.r();
                            }

                            writeMaterial(output, s, t);
                        }
                    }

                    diffuseImages.push_back(material.get());
                }
            }
        }
    }

    // Create the texture array.
    if ( diffuseImages.size() > 0 )
    {
        osg::Image* first = diffuseImages.front();

        out._rgbhTextureAtlas = new osg::Texture2DArray();
        out._rgbhTextureAtlas->setTextureSize( first->s(), first->t(), diffuseImages.size() );
        out._rgbhTextureAtlas->setWrap( osg::Texture::WRAP_S, osg::Texture::REPEAT );
        out._rgbhTextureAtlas->setWrap( osg::Texture::WRAP_T, osg::Texture::REPEAT );
        out._rgbhTextureAtlas->setFilter( osg::Texture::MIN_FILTER, osg::Texture::LINEAR_MIPMAP_LINEAR );
        out._rgbhTextureAtlas->setFilter( osg::Texture::MAG_FILTER, osg::Texture::LINEAR );
        out._rgbhTextureAtlas->setMaxAnisotropy( 4.0f );

        for(unsigned i=0; i<diffuseImages.size(); ++i)
        {
            out._rgbhTextureAtlas->setImage( i, diffuseImages[i].get() );
        }

        //if (materialImages.size() > 0)
        //{
        //    //out._materialTextureAtlas = new osg::Texture2DArray();
        //    //out._materialTextureAtlas->setTextureSize( first->s(), first->t(), diffuseImages.size() );
        //    //out._materialTextureAtlas->setWrap( osg::Texture::WRAP_S, osg::Texture::REPEAT );
        //    //out._materialTextureAtlas->setWrap( osg::Texture::WRAP_T, osg::Texture::REPEAT );
        //    //out._materialTextureAtlas->setFilter( osg::Texture::MIN_FILTER, osg::Texture::LINEAR_MIPMAP_LINEAR );
        //    //out._materialTextureAtlas->setFilter( osg::Texture::MAG_FILTER, osg::Texture::LINEAR );
        //    //out._materialTextureAtlas->setMaxAnisotropy( 4.0f );

        //    for(unsigned i=0; i<materialImages.size(); ++i)
        //    {
        //        out._rgbhTextureAtlas->setImage( diffuseImages.size()+i, materialImages[i].get() );
        //    }
        //}

        OE_INFO << LC << "Catalog \"" << this->name().get()
            << "\" atlas size = "<< diffuseImages.size()
            << std::endl;
    }

    return out._rgbhTextureAtlas.valid();
}

SplatCatalog*
SplatCatalog::read(const URI& uri, const osgDB::Options* options)
{
    osg::ref_ptr<SplatCatalog> catalog;

    osg::ref_ptr<XmlDocument> doc = XmlDocument::load( uri, options );
    if ( doc.valid() )
    {
        catalog = new SplatCatalog();
        catalog->fromConfig( doc->getConfig().child("splat_catalog") );
        if ( catalog->empty() )
        {
            OE_WARN << LC << "Catalog is empty! (" << uri.full() << ")\n";
            catalog = 0L;
        }
        else
        {
            OE_INFO << LC << "Catalog \"" << catalog->name().get() << "\""
                << " contains " << catalog->getClasses().size()
                << " classes.\n";
        }
    }
    else
    {
        OE_WARN << LC << "Failed to read catalog from " << uri.full() << "\n";
    }

    return catalog.release();
}

//...................................................................

void
SplatTextureDef::resizeGLObjectBuffers(unsigned maxSize)
{
    if (_rgbhTextureAtlas.valid())
        _rgbhTextureAtlas->resizeGLObjectBuffers(maxSize);

    if (_materialTextureAtlas.valid())
        _materialTextureAtlas->resizeGLObjectBuffers(maxSize);

    if (_splatLUTBuffer.valid())
        _splatLUTBuffer->resizeGLObjectBuffers(maxSize);
}

void
SplatTextureDef::releaseGLObjects(osg::State* state) const
{
    if (_rgbhTextureAtlas.valid())
        _rgbhTextureAtlas->releaseGLObjects(state);

    if (_materialTextureAtlas.valid())
        _materialTextureAtlas->releaseGLObjects(state);

    if (_splatLUTBuffer.valid())
        _splatLUTBuffer->releaseGLObjects(state);
}
