# 実装ソースは 2 つのターゲットにコンパイルする。
#   opencv_unity_native (SHARED) — 配布物。公開 ABI だけをエクスポートする
#   ocvu_static         (STATIC) — L1 テスト用
#
# テストを SHARED にリンクすると、DLL がエクスポートしていない内部シンボル
# (ocvu::set_last_error など) に到達できず link エラーになる。
# よってテストは STATIC 側へリンクする。
set(OCVU_SOURCES
    src/ocvu_version.cpp
    src/ocvu_error.cpp
    src/ocvu_status.cpp
    src/ocvu_debug.cpp
    src/ocvu_opencv_info.cpp
    src/ocvu_mat_table.cpp
    src/ocvu_mat.cpp
    src/ocvu_mat_buffer.cpp
    src/ocvu_imgproc.cpp
    src/ocvu_imgcodecs.cpp
    src/ocvu_objdetect.cpp
    src/ocvu_features.cpp
    src/ocvu_geometry.cpp
    src/ocvu_calibration.cpp
    src/ocvu_pose.cpp
    src/ocvu_aruco.cpp
    src/ocvu_imgproc_ops.cpp
    src/ocvu_imgproc_shape.cpp
    src/ocvu_core_ops.cpp
    src/ocvu_matching.cpp
    src/ocvu_stereo.cpp
)

# **iOS だけ静的ライブラリにする。**
#
# iOS はアプリの外から .dylib を読み込めない。Unity は .a を受け取って
# IL2CPP のバイナリへ静的リンクし、P/Invoke は DllImport("__Internal") で
# 解決する。**SHARED のままでもビルドは成功する**ので、Unity に入れて
# 初めて壊れる —— v0.1.0 の「ビルドできた ≠ 動く」と同じ形である。
#
# **Web / Wasm も同じ理由で静的にする。** wasm に共有ライブラリという
# 仕組みは無く、Unity は .a を受け取って Emscripten のリンク段で取り込む。
# P/Invoke は iOS と同じく DllImport("__Internal") で解決する。
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" OR EMSCRIPTEN)
  set(OCVU_LIBRARY_KIND STATIC)
else()
  set(OCVU_LIBRARY_KIND SHARED)
endif()

add_library(opencv_unity_native ${OCVU_LIBRARY_KIND} ${OCVU_SOURCES})
target_include_directories(opencv_unity_native
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)
target_compile_definitions(opencv_unity_native PRIVATE OCVU_BUILDING_DLL)
set_target_properties(opencv_unity_native PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    OUTPUT_NAME opencv_unity_native
)

add_library(ocvu_static STATIC ${OCVU_SOURCES})
target_include_directories(ocvu_static
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
           $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
)
# PUBLIC にすることで、リンクするテスト側のヘッダ展開でも
# __declspec(dllimport) が付かなくなる。
target_compile_definitions(ocvu_static PUBLIC OCVU_STATIC)

if(OCVU_WITH_OPENCV)
    target_link_libraries(opencv_unity_native PRIVATE ${OpenCV_LIBS})
    target_link_libraries(ocvu_static PUBLIC ${OpenCV_LIBS})

    # **静的ライブラリを配るときは、依存アーカイブを自分で束ねる。**
    #
    # CMake は STATIC ライブラリに依存アーカイブを取り込まない —— 記録するのは
    # usage requirement だけである。したがって出来る libopencv_unity_native.a は
    # 自分の object しか含まず、`cv::cvtColor` などは**未解決のまま**になる。
    # Unity がそれを Xcode プロジェクトへ足してリンクした時点で失敗する。
    #
    # **ビルドは成功する。** 壊れるのは実機に載せる段で、それは
    # 「ビルドできた ≠ 動く」の最も遠い形である（レビューで発見）。
    #
    # libtool -static は macOS の標準ツールで、複数のアーカイブを 1 つに
    # 束ねられる。iOS のビルドは必ず macOS 上で走るので、存在は保証される。
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        find_program(OCVU_LIBTOOL libtool REQUIRED)

        # OpenCV の静的ライブラリ（third-party 込み）を集める。
        # ${OpenCV_LIBS} は target 名なので、実ファイルへ解決する。
        set(OCVU_BUNDLE_INPUTS "")
        foreach(_lib IN LISTS OpenCV_LIBS)
            list(APPEND OCVU_BUNDLE_INPUTS "$<TARGET_FILE:${_lib}>")
        endforeach()

        # OpenCV が bundle する third-party（libpng / libjpeg-turbo / zlib /
        # kleidicv 等）は OpenCV_LIBS の target には現れないので、インストール木
        # から直接拾う。**実測した配置**（M4 の CI artifact、iOS）:
        #
        #   <root>/lib/opencv5/3rdparty/*.a   ← 実際にここ
        #   <root>/lib/*.a                     ← opencv_* 本体
        #
        # 版番号つきのディレクトリ名（opencv5）を決め打ちにせず、glob で拾う。
        file(GLOB OCVU_OPENCV_3RDPARTY
             "${OCVU_OPENCV_ROOT}/lib/opencv*/3rdparty/*.a"
             "${OCVU_OPENCV_ROOT}/lib/3rdparty/*.a"
             "${OCVU_OPENCV_ROOT}/share/OpenCV/3rdparty/lib/*.a")
        list(APPEND OCVU_BUNDLE_INPUTS ${OCVU_OPENCV_3RDPARTY})

        # **1 つも集まらなかったら止める。** 空のまま束ねると、
        # 「libtool は成功したのに中身は自分の object だけ」になり、
        # **この手当てが在ることが逆に安心材料になってしまう。**
        list(LENGTH OCVU_OPENCV_3RDPARTY _ocvu_3p_count)
        if(_ocvu_3p_count EQUAL 0)
            message(FATAL_ERROR
                "iOS: OpenCV の静的ライブラリが 1 つも見つかりません "
                "(OCVU_OPENCV_ROOT=${OCVU_OPENCV_ROOT})。"
                "束ねる相手が無いまま .a を配ると、リンク時に未解決シンボルになります。")
        endif()

        set(OCVU_BUNDLED "${CMAKE_CURRENT_BINARY_DIR}/bundled/libopencv_unity_native.a")
        add_custom_command(
            TARGET opencv_unity_native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/bundled"
            COMMAND ${OCVU_LIBTOOL} -static -o "${OCVU_BUNDLED}"
                    "$<TARGET_FILE:opencv_unity_native>" ${OCVU_BUNDLE_INPUTS}
            # 束ねた物で置き換える。**別名で残すと、配る側がどちらを拾うか
            # 決めなければならない** —— 決め損なうと未解決シンボルのほうが配られる。
            COMMAND ${CMAKE_COMMAND} -E copy "${OCVU_BUNDLED}" "$<TARGET_FILE:opencv_unity_native>"
            COMMENT "iOS: bundling OpenCV into libopencv_unity_native.a"
            VERBATIM
        )

    endif()

    # **Web / Wasm も同じ理由で束ねる。** CMake が STATIC に依存を取り込まない
    # のは platform に依らないので、iOS で踏んだ欠陥がそのまま再来する。
    #
    # **道具が違う。** macOS の libtool は無いので emar（llvm-ar の wrapper）の
    # MRI script を使う。`llvm-ar -M` が `create` / `addlib` / `save` を受ける
    # （同梱の llvm-ar --help で確認）。addlib はアーカイブの中身を展開して
    # 取り込むので、libtool -static と同じ結果になる。
    if(EMSCRIPTEN)
        # **OpenCV_LIBS だけでは足りない。**
        #
        # COMPONENTS に書いた module の target しか入らないので、
        # **推移的に引かれる module が漏れる。** 実測（2026-09-03）:
        # 束ねた .a に cv::flann の未定義が 29 件残った
        # （flann は features / objdetect の依存として引かれるが、
        # COMPONENTS には書いていない）。
        #
        # **ビルドもリンクも成功する。** 壊れるのは Unity が
        # Emscripten でリンクする段で、これも「ビルドできた ≠ 動く」である。
        #
        # **だから install 木に在る .a を全部束ねる。** 使わない module の
        # object が入るが、最終リンクで捨てられるだけで害は無い ——
        # **「何を参照しているか」を CMake の変数から推測するより、
        # 「木に在る物を全部入れる」ほうが漏れようがない。**
        set(OCVU_BUNDLE_INPUTS "")
        file(GLOB OCVU_OPENCV_MODULES "${OCVU_OPENCV_ROOT}/lib/libopencv_*.a")
        list(LENGTH OCVU_OPENCV_MODULES _ocvu_mod_count)
        if(_ocvu_mod_count EQUAL 0)
            message(FATAL_ERROR
                "web-wasm: OpenCV の module アーカイブが 1 つも見つかりません "
                "(OCVU_OPENCV_ROOT=${OCVU_OPENCV_ROOT}/lib)。")
        endif()
        list(APPEND OCVU_BUNDLE_INPUTS ${OCVU_OPENCV_MODULES})

        # third-party は OpenCV_LIBS の target に現れないのでインストール木から拾う。
        # **配置は platform で違いうるので glob で拾う**（iOS で実測した 3 通りを踏襲）。
        file(GLOB OCVU_OPENCV_3RDPARTY
             "${OCVU_OPENCV_ROOT}/lib/opencv*/3rdparty/*.a"
             "${OCVU_OPENCV_ROOT}/lib/3rdparty/*.a"
             "${OCVU_OPENCV_ROOT}/share/OpenCV/3rdparty/lib/*.a")

        # **1 つも集まらなかったら止める。** 空のまま束ねると
        # 「emar は成功したのに中身は自分の object だけ」になり、
        # **この手当てが在ることが逆に安心材料になってしまう。**
        list(LENGTH OCVU_OPENCV_3RDPARTY _ocvu_3p_count)
        if(_ocvu_3p_count EQUAL 0)
            message(FATAL_ERROR
                "web-wasm: OpenCV の 3rdparty アーカイブが 1 つも見つかりません "
                "(OCVU_OPENCV_ROOT=${OCVU_OPENCV_ROOT})。"
                "束ねる相手が無いまま .a を配ると、Unity のリンク段で未解決になります。")
        endif()

        # **Unity が自分で持っている third-party は束ねない。**
        #
        # Unity の WebGL 支援は libpng を同梱しており、こちらが OpenCV の
        # 3rdparty をそのまま束ねると **リンク段でシンボルが衝突する**
        # （2026-09-03 に実測。27 件、9 シンボル）:
        #
        #     wasm-ld: error: duplicate symbol: png_get_eXIf
        #     >>> defined in .../GameAssembly...
        #     >>> defined in .../WebGLSupport/BuildTools/lib/modules/libpng.a
        #
        # **ビルドもここまでは全部通る** —— Player をリンクする段で初めて出る。
        #
        # **一覧で持つ。** 「Unity が何を同梱しているか」はこちらが決められない
        # ので、増えたら足すことになる。**名前を書くのではなく、衝突したら
        # ここへ足すこと**を明示しておく。
        set(OCVU_UNITY_PROVIDED_3RDPARTY libpng)
        foreach(_provided IN LISTS OCVU_UNITY_PROVIDED_3RDPARTY)
            # **バックスラッシュを 2 つ書く。**
            #
            # CMake の引用符つき引数では \. が . に畳まれるので、
            # 正規表現が libpng.a$（. は任意 1 文字）になる。
            #
            # **前回はコメントだけ直してコードを直していなかった**（再レビューの指摘）。
            # **直っていないことより、検討済みに見えることのほうが悪い。**
            list(FILTER OCVU_OPENCV_3RDPARTY EXCLUDE REGEX "lib${_provided}\\.a$")
        endforeach()

        list(APPEND OCVU_BUNDLE_INPUTS ${OCVU_OPENCV_3RDPARTY})
        message(STATUS "web-wasm: bundling 3rdparty: ${OCVU_OPENCV_3RDPARTY}")

        # MRI script を生成して emar に食わせる。**generator expression を
        # 含むので file(GENERATE) を使う** —— configure 時の file(WRITE) では
        # $<TARGET_FILE:...> が展開されない。
        set(OCVU_MRI "${CMAKE_CURRENT_BINARY_DIR}/bundle-wasm.mri")
        set(OCVU_BUNDLED "${CMAKE_CURRENT_BINARY_DIR}/bundled/libopencv_unity_native.a")
        set(_ocvu_mri_body "create ${OCVU_BUNDLED}
addlib $<TARGET_FILE:opencv_unity_native>
")
        foreach(_in IN LISTS OCVU_BUNDLE_INPUTS)
            string(APPEND _ocvu_mri_body "addlib ${_in}
")
        endforeach()
        string(APPEND _ocvu_mri_body "save
end
")
        file(GENERATE OUTPUT "${OCVU_MRI}" CONTENT "${_ocvu_mri_body}")

        # **find_file / find_program を使わない。**
        #
        # Emscripten の toolchain は CMAKE_FIND_ROOT_PATH_MODE_* を ONLY に
        # するので、**探索が sysroot の中に閉じ込められる。**
        # `OCVU_EMSCRIPTEN_ROOT` は sysroot の外なので、PATHS で明示しても
        # 見つからない（2026-09-03 に実測:
        # `Could not find OCVU_EMAR_PY using the following files: emar.py`。
        # **cache には正しい値が入っていた**ので、値ではなく探し方の問題である）。
        #
        # `add-a-platform` skill の罠 3 は `find_package` の話だが、
        # **`find_file` / `find_program` にも同じことが起きる。**
        #
        # **在り処は分かっているので探さない。** 組み立てて、無ければ
        # その場で止める（`NO_CMAKE_FIND_ROOT_PATH` を足す手もあるが、
        # **探索の設定に依存しないほうが読んで分かる**）。
        set(OCVU_EMAR_PY "${OCVU_EMSCRIPTEN_ROOT}/emscripten/emar.py")
        if(NOT EXISTS "${OCVU_EMAR_PY}")
            message(FATAL_ERROR "emar.py が見つかりません: ${OCVU_EMAR_PY}")
        endif()

        # python は同梱に在ればそれを、無ければ PATH のものを使う。
        # **同梱を先に見る** —— emcc 自身がそれで動いている組み合わせだからである。
        # **emar の実行ファイルを直接使う。**
        #
        # 最初は `python emar.py` にしていたが、**emsdk には同梱の python が
        # 無い**（Unity の同梱にはある）ので CI で起動できず、
        # `emar -M が失敗しました (exit no such file or directory)` になった。
        #
        # **emar 自体はどちらの木にも在る** —— Linux / macOS は拡張子なし、
        # Windows は .bat である。**在るほうを採る。**
        # **順序ではなく host の OS で選ぶ。**
        #
        # emsdk は `emar` と `emar.bat` を**両方置く**ので、
        # 「在るほうを採る」と Linux でも `.bat` を掴む。実測（CI）:
        #
        #     bundling with: .../emscripten/emar.bat;-M
        #     emar -M が失敗しました (exit permission denied)
        #
        # **「在るほうを採る」が効くのは、片方しか無いときだけである。**
        if(CMAKE_HOST_WIN32)
            set(_ar_names "emar.bat" "emar")
        else()
            set(_ar_names "emar" "emar.bat")
        endif()
        set(OCVU_EMAR_CMD "")
        foreach(_n IN LISTS _ar_names)
            set(_ar "${OCVU_EMSCRIPTEN_ROOT}/emscripten/${_n}")
            if(EXISTS "${_ar}")
                set(OCVU_EMAR_CMD "${_ar}")
                break()
            endif()
        endforeach()

        # **見つからなければ python 経由に落とす**（そちらも無ければ止める）。
        set(OCVU_EM_PYTHON "")
        if(NOT OCVU_EMAR_CMD)
            foreach(_py "${OCVU_EMSCRIPTEN_ROOT}/python/python.exe"
                        "${OCVU_EMSCRIPTEN_ROOT}/python/python3"
                        "${OCVU_EMSCRIPTEN_ROOT}/python/bin/python3")
                if(EXISTS "${_py}")
                    set(OCVU_EM_PYTHON "${_py}")
                    break()
                endif()
            endforeach()
            if(NOT OCVU_EM_PYTHON)
                find_program(OCVU_EM_PYTHON NAMES python3 python NO_CMAKE_FIND_ROOT_PATH REQUIRED)
            endif()
            set(OCVU_EMAR_CMD "${OCVU_EM_PYTHON}")
        endif()

        add_custom_command(
            TARGET opencv_unity_native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/bundled"
            # **shell を通さないのでリダイレクトは書けない。** driver 経由で
            # stdin を渡す（cmake/run_expect_failure.cmake と同じ理由）。
            COMMAND ${CMAKE_COMMAND}
                    -DOCVU_EMAR_CMD=${OCVU_EMAR_CMD}
                    -DOCVU_EMAR_PY=${OCVU_EM_PYTHON}
                    -DOCVU_EMAR=${OCVU_EMAR_PY}
                    -DOCVU_MRI=${OCVU_MRI}
                    -DOCVU_OUTPUT=${OCVU_BUNDLED}
                    -P "${CMAKE_SOURCE_DIR}/cmake/bundle_wasm_archive.cmake"
            # 束ねた物で置き換える。**別名で残すと、配る側がどちらを拾うかを
            # 決めなければならない** —— 決め損なうと未解決シンボルのほうが配られる。
            COMMAND ${CMAKE_COMMAND} -E copy "${OCVU_BUNDLED}" "$<TARGET_FILE:opencv_unity_native>"
            COMMENT "web-wasm: bundling OpenCV into libopencv_unity_native.a"
            VERBATIM
        )
    endif()
endif()
