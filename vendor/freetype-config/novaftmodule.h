/* Nova's FreeType module list.
 *
 * Replaces FreeType's default `ftmodule.h`, which registers every font format
 * the library knows -- PFR, BDF, PCF, Windows FNT, Type 42, the SDF and SVG
 * renderers. Nova only ever opens the TrueType/OpenType fonts it bundles (or
 * one the user points it at), so the rest is dropped: less to compile, less to
 * ship, and no LZW/gzip decompressors linked in for bitmap font formats.
 */
FT_USE_MODULE( FT_Module_Class, autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, t1_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, t1cid_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
FT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )
