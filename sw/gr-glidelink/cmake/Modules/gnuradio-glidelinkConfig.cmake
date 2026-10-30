find_package(PkgConfig)

PKG_CHECK_MODULES(PC_GR_GLIDELINK gnuradio-glidelink)

FIND_PATH(
    GR_GLIDELINK_INCLUDE_DIRS
    NAMES gnuradio/glidelink/api.h
    HINTS $ENV{GLIDELINK_DIR}/include
        ${PC_GLIDELINK_INCLUDEDIR}
    PATHS ${CMAKE_INSTALL_PREFIX}/include
          /usr/local/include
          /usr/include
)

FIND_LIBRARY(
    GR_GLIDELINK_LIBRARIES
    NAMES gnuradio-glidelink
    HINTS $ENV{GLIDELINK_DIR}/lib
        ${PC_GLIDELINK_LIBDIR}
    PATHS ${CMAKE_INSTALL_PREFIX}/lib
          ${CMAKE_INSTALL_PREFIX}/lib64
          /usr/local/lib
          /usr/local/lib64
          /usr/lib
          /usr/lib64
          )

include("${CMAKE_CURRENT_LIST_DIR}/gnuradio-glidelinkTarget.cmake")

INCLUDE(FindPackageHandleStandardArgs)
FIND_PACKAGE_HANDLE_STANDARD_ARGS(GR_GLIDELINK DEFAULT_MSG GR_GLIDELINK_LIBRARIES GR_GLIDELINK_INCLUDE_DIRS)
MARK_AS_ADVANCED(GR_GLIDELINK_LIBRARIES GR_GLIDELINK_INCLUDE_DIRS)
