cmake_minimum_required(VERSION 3.16)
project(SoapyGlideLink CXX)

find_package(SoapySDR "0.8" REQUIRED)

# libiio: pkg-config where there is one (Linux), else the header and library directly
# (Windows, e.g. a radioconda / conda-forge environment)
find_package(PkgConfig QUIET)
if(PKG_CONFIG_FOUND)
	pkg_check_modules(LIBIIO QUIET libiio)
endif()
if(NOT LIBIIO_FOUND)
	find_path(LIBIIO_INCLUDE_DIRS iio.h REQUIRED)
	find_library(LIBIIO_LIBRARIES NAMES iio libiio REQUIRED)
endif()

set(GLIDELINK_LIBS ${LIBIIO_LIBRARIES})
if(WIN32)
	list(APPEND GLIDELINK_LIBS ws2_32)       # sockets of the streamd client
endif()

SOAPY_SDR_MODULE_UTIL(
	TARGET glidelinkSupport
	SOURCES GlideLink.cpp
	LIBRARIES ${GLIDELINK_LIBS}
)
target_include_directories(glidelinkSupport PRIVATE ${LIBIIO_INCLUDE_DIRS})
