cmake_minimum_required(VERSION 3.16)
project(SoapyGlideLink CXX)

find_package(SoapySDR "0.8" REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBIIO REQUIRED libiio)

SOAPY_SDR_MODULE_UTIL(
	TARGET glidelinkSupport
	SOURCES GlideLink.cpp
	LIBRARIES ${LIBIIO_LIBRARIES}
)
target_include_directories(glidelinkSupport PRIVATE ${LIBIIO_INCLUDE_DIRS})
