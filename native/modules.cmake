# module 名 → その module を実装するソース。**正本である。**
#
# **spec のファイル名と対応する** —— bindings/spec/<module>.json が 1 つあれば、
# ここに <module> の項が 1 つある。ずれると Task 3 の検査が落ちる。
#
# **1 つの用途が複数 module にまたがることがある。** ocvu_calibration.cpp は
# objdetect / calib / imgproc の 3 つに関数を出すが、実装は 1 ファイルである。
# **そういうファイルは、最も外せない module に置く** —— ここでは calib。
# 外せる単位を作るのが目的なので、「どの module の一部か」より
# 「どれを外したら一緒に消えるべきか」で決める。

set(OCVU_MODULE_infra
    src/ocvu_version.cpp
    src/ocvu_error.cpp
    src/ocvu_status.cpp
    src/ocvu_debug.cpp
    src/ocvu_opencv_info.cpp
)

set(OCVU_MODULE_core
    src/ocvu_mat_table.cpp
    src/ocvu_mat.cpp
    src/ocvu_mat_buffer.cpp
    src/ocvu_core_ops.cpp
)

set(OCVU_MODULE_imgproc
    src/ocvu_imgproc.cpp
    src/ocvu_imgproc_ops.cpp
    src/ocvu_imgproc_shape.cpp
)

set(OCVU_MODULE_imgcodecs  src/ocvu_imgcodecs.cpp)
set(OCVU_MODULE_objdetect  src/ocvu_objdetect.cpp src/ocvu_aruco.cpp)
set(OCVU_MODULE_features   src/ocvu_features.cpp src/ocvu_matching.cpp)
set(OCVU_MODULE_geometry   src/ocvu_geometry.cpp src/ocvu_pose.cpp)
set(OCVU_MODULE_calib      src/ocvu_calibration.cpp)
set(OCVU_MODULE_stereo     src/ocvu_stereo.cpp)

# **dnn は Task 3 で ocvu_dnn.cpp（C ABI 関数本体）を足すまでこの 1 本だけ。**
# ここに存在しないファイルを書くと configure が落ちる —— handle 表だけを
# 先に固定するのがこの module の Task 2 の役目である。
set(OCVU_MODULE_dnn        src/ocvu_dnn_table.cpp)

# **infra と core は外せない。** last-error も status も Mat も、
# 他の全 module が使う。外せる単位から明示的に除く。
set(OCVU_REQUIRED_MODULES infra core)

# 既定で全部入れる。profile はこの一覧から引く形で表す。
set(OCVU_ALL_MODULES
    infra core imgproc imgcodecs objdetect features geometry calib stereo dnn)
