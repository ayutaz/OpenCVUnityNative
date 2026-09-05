/*
 * このファイルは生成物である。手で編集しないこと。
 * 正本: bindings/spec/imgproc.json
 * 生成: ./tools/dev.ps1 generate
 */
#ifndef OCVU_IMGPROC_H
#define OCVU_IMGPROC_H

#include "opencv_unity_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 色空間を変換する。dst の形状と型は結果に応じて上書きされる。src と dst が同じ handle なら OCVU_STATUS_INVALID_ARGUMENT を返す（OpenCV の in-place 対応は関数ごとに異なり、曖昧さを ABI に持ち込まない）。OpenCV 由来の失敗は OCVU_STATUS_OPENCV_ERROR になる。 */
OCVU_API ocvu_status ocvu_cvt_color(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t code);

/* width x height に拡大縮小する。width / height が 1 未満なら OCVU_STATUS_INVALID_ARGUMENT。src と dst に同じ handle を渡した場合も同様に拒否する。 */
OCVU_API ocvu_status ocvu_resize(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t width, int32_t height, int32_t interpolation);

/* Gaussian ぼかしを掛ける。ksize は正の奇数でなければならず、そうでなければ OCVU_STATUS_INVALID_ARGUMENT。sigma に 0 を渡すと OpenCV が ksize から算出する。 */
OCVU_API ocvu_status ocvu_gaussian_blur(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t ksize_width, int32_t ksize_height, double sigma_x, double sigma_y);

/* src の歪みを camera_matrix と dist_coeffs で補正して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。camera_matrix は行優先の 3x3（double 9 個）、dist_coeffs は OpenCV が受ける長さ（4 / 5 / 8 / 12 / 14 個）でなければならない。camera_matrix_length と dist_coeffs_length はどちらもバイト数で、この ABI の length は全部そうである。呼ぶ側を信用せず、長さが合わなければ何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。失敗したときは dst を書き換えない。src と dst に同じ handle を渡してもよい（結果を求めてから入れ替えるので、cvtColor と違い in-place 呼び出しを禁じていない）。 */
OCVU_API ocvu_status ocvu_undistort(ocvu_mat_handle src, const double* camera_matrix, int64_t camera_matrix_length, const double* dist_coeffs, int64_t dist_coeffs_length, ocvu_mat_handle dst);

/* src を二値化して dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。type は OCVU_THRESH_BINARY から OCVU_THRESH_TOZERO_INV までのいずれかで、OCVU_THRESH_OTSU を or して渡すとしきい値を画像から自動で選ぶ（そのとき threshold_value は無視される）。それ以外のビットが立っていれば OCVU_STATUS_INVALID_ARGUMENT を返す —— cv::THRESH_TRIANGLE はこの ABI に出していないので、or して渡しても断る。out_computed_threshold には実際に使われたしきい値が入る。これは Otsu を指定したときに選ばれた値を知る唯一の手段である。out_computed_threshold は NULL でもよく、その場合は書かない。NULL でないならどの失敗経路でも 0 を書く。src の型には OpenCV 側の制約がある: 32 bit 符号つき整数は拒否され、OCVU_THRESH_OTSU が使えるのは 8 bit 符号なし 1 channel と 16 bit 符号なし 1 channel だけである（複数 channel の画像に or して渡すと OpenCV が例外を投げる）。src と dst に同じ handle を渡してもよい —— 結果を一時に求めてから入れるので、cvtColor と違い in-place 呼び出しを禁じていない。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_threshold(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold_value, double max_value, int32_t type, double* out_computed_threshold);

/* src に Canny のエッジ検出を掛けて dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ大きさの 8 bit 1 channel になる（エッジが 255、それ以外が 0）。src は 8 bit でなければならず、そうでなければ OpenCV が例外を投げる。threshold1 と threshold2 はどちらも 0 以上でなければならず、負なら OCVU_STATUS_INVALID_ARGUMENT を返す。小さいほうが弱いエッジをつなぐ下限、大きいほうが強いエッジの下限として使われる。aperture_size は Sobel の窓の大きさで、3 か 5 か 7 でなければならない。l2_gradient は 0 以外を真として扱い、勾配の大きさを L2 ノルムで測る（0 なら L1 で、速いが粗い）。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_canny(ocvu_mat_handle src, ocvu_mat_handle dst, double threshold1, double threshold2, int32_t aperture_size, int32_t l2_gradient);

/* src に形態素演算（収縮・膨張・開・閉・勾配・トップハット・ブラックハット）を掛けて dst に入れる。dst は結果に応じて丸ごと置き換わり、src と同じ形状・型になる。op は OCVU_MORPH_* のいずれか、kernel_shape は OCVU_MORPH_SHAPE_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。kernel_width と kernel_height は構造要素の大きさで、どちらも 1 以上でなければならない。iterations は演算を繰り返す回数で、1 以上でなければならない。構造要素の中心は OpenCV が自動で決める。src と dst に同じ handle を渡してもよい。handle が無効なら OCVU_STATUS_INVALID_HANDLE。構造要素が大きすぎて確保できない場合を含め、OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_morphology_ex(ocvu_mat_handle src, ocvu_mat_handle dst, int32_t op, int32_t kernel_shape, int32_t kernel_width, int32_t kernel_height, int32_t iterations);

/* image の中で templ に似ている場所の応答画像を作って dst に入れる。dst は結果に応じて丸ごと置き換わり、列数は image の列数から templ の列数を引いて 1 を足したもの、行数も同じ引き算で決まり、型は OCVU_MAT_TYPE_32FC1 である。method は OCVU_TM_* のいずれかで、それ以外は OCVU_STATUS_INVALID_ARGUMENT を返す。OCVU_TM_SQDIFF と OCVU_TM_SQDIFF_NORMED は値が小さいほど似ており、他の 4 つは大きいほど似ている —— 最も似た位置を探すときに、最小と最大のどちらを取るかが逆になる。image と templ は 8 bit か 32 bit 浮動小数で、しかも同じ型でなければならない。templ の行数と列数はどちらも image のそれ以下でなければならず、そうでなければ OCVU_STATUS_INVALID_ARGUMENT を返す。この大きさの検査はこの ABI が自分で行う —— 実測（2026-09-05）では、両方向とも templ のほうが大きいとき OpenCV は例外を投げず image と templ を入れ替えて計算するので、任せると上に書いた出力の形が黙って破られる。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_match_template(ocvu_mat_handle image, ocvu_mat_handle templ, ocvu_mat_handle dst, int32_t method);

/* src を射影変換で変形して dst に入れる。dst は結果に応じて丸ごと置き換わり、height 行 width 列で src と同じ型になる。transform は 3x3 の変換行列を持つ Mat の handle である —— ocvu_get_perspective_transform や ocvu_find_homography の出力をそのまま渡せる形にしてあり、行列を C# 側へ読み出して詰め替える往復を呼ぶ側に強いない。3 行 3 列でなければ OCVU_STATUS_INVALID_ARGUMENT を返す。width と height はどちらも 1 以上でなければならない。interpolation は OCVU_INTER_* のいずれか、border_mode は OCVU_BORDER_* のいずれかで、それ以外は拒否する。border_mode は変換後に元の画像の外を参照した画素をどう埋めるかで、OCVU_BORDER_CONSTANT は 0 で埋める。src と dst に同じ handle を渡してもよい —— 結果を一時に求めてから入れるので、in-place 呼び出しを禁じていない。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返し、失敗したときは dst を書き換えない。 */
OCVU_API ocvu_status ocvu_warp_perspective(ocvu_mat_handle src, ocvu_mat_handle dst, ocvu_mat_handle transform, int32_t width, int32_t height, int32_t interpolation, int32_t border_mode);

/* 確率的 Hough 変換で src から線分を検出し、out_lines へ書いて本数を out_count に返す。src は 8 bit 1 channel の 2 値画像でなければならない（ocvu_canny の出力をそのまま渡せる）。src は書き換えない —— OpenCV は入力を書き換えることがあると宣言しているので、実装は写しを渡す。rho は距離の刻み（画素）で 0 より大きく、theta は角度の刻み（ラジアン）で 0 より大きく、threshold は投票数の下限で 1 以上でなければならない。min_line_length より短い線分は捨て、max_line_gap 以下の切れ目はつなぐ。capacity は out_lines の要素数である（バイト数でも本数でもない）—— 線分 1 本につき x1, y1, x2, y2 の 4 要素を使うので、n 本を受けるには capacity が n の 4 倍以上でなければならない。足りないときは out_lines に 1 バイトも書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_count に実際に見つかった本数を入れる（呼ぶ側はそれを 4 倍して確保し直し、呼び直せる）。out_count に入るのは常に本数であって要素数ではない。capacity が 0 のときだけ out_lines は NULL でよく、それが必要な本数だけを問い合わせる呼び方である。capacity が 1 以上なのに out_lines が NULL なら OCVU_STATUS_NULL_POINTER。1 本も見つからないのは誤りではない —— OCVU_STATUS_OK を返して out_count に 0 を入れる。out_count が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返し、通ったあとはどの失敗経路でも out_count に 0 を書く。handle が無効なら OCVU_STATUS_INVALID_HANDLE。src の型が合わないなど OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_hough_lines_p(ocvu_mat_handle src, double rho, double theta, int32_t threshold, double min_line_length, double max_line_gap, float* out_lines, int32_t capacity, int32_t* out_count);

/* 既に見つけてある角点の位置を副画素精度へ精緻化する。points は入出力兼用である —— 渡した位置を読み、精緻化した位置でその場を上書きする。この ABI で唯一この形をしていて、他の buffer 引数は入力か出力のどちらかである。x と y が交互に並ぶ 32 bit 浮動小数の配列で、points_length はそのバイト数である（要素数でも点数でもない）。point_count は 1 以上 OCVU_CORNER_MAX_POINTS 以下でなければならず、points_length が point_count の 2 倍の浮動小数を収めるバイト数に満たなければ、何も読まずに OCVU_STATUS_INVALID_ARGUMENT を返す。win_size は探索窓の半径（画素）で 1 以上 OCVU_CORNER_MAX_WINDOW 以下、zero_zone は窓の中央で無視する領域の半径で -1 なら無視しない、max_iterations は 1 以上、epsilon は移動量がこれを下回ったら打ち切る値である。src は 1 channel でなければならない —— cv::cornerSubPix 自身が縛るのは channel の数だけだが、実測では 8 bit と 32 bit 浮動小数だけが通り、16 bit は OpenCV の内部でさらに拒否される。断った場合は points を 1 バイトも書き換えない。呼ぶ側の buffer を直接 OpenCV へ渡さず写してから戻すので、OpenCV が例外を投げたときも points は書きかけで残らない。points が NULL なら OCVU_STATUS_NULL_POINTER。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。 **win_size と zero_zone には上限がある** —— cv::cornerSubPix はこの 2 つを int のまま 2 倍して窓の寸法にするので、大きな値は符号あり整数のオーバーフローになる。実測では zero_zone に 2 の 30 乗を渡すとプロセスがアクセス違反で即死し、win_size に INT32_MAX を渡すと無意味な窓で OCVU_STATUS_OK が返った。zero_zone は -1（無視しない）または 0 以上 OCVU_CORNER_MAX_WINDOW 以下でなければならず、範囲外は OCVU_STATUS_INVALID_ARGUMENT を返す。 */
OCVU_API ocvu_status ocvu_corner_sub_pix(ocvu_mat_handle src, float* points, int64_t points_length, int32_t point_count, int32_t win_size, int32_t zero_zone, int32_t max_iterations, double epsilon);

/* src から輪郭を検出し、全輪郭の点を out_points へ、輪郭ごとの点数を out_counts へ書く。入れ子の可変長を、平らな 2 本の配列で表している —— 呼ぶ側は out_counts を前から足していけば、out_points の中で各輪郭がどこからどこまでかが決まる。src は 8 bit 1 channel の 2 値画像でなければならない（0 でない画素を 1 と見なす）。mode は OCVU_RETR_EXTERNAL から OCVU_RETR_TREE までのいずれかで、cv::RETR_FLOODFILL に当たる定数は出していない（32 bit のラベル画像を要求するので、この関数が受ける 8 bit の 2 値画像では使えない）。method は OCVU_CHAIN_APPROX_NONE か OCVU_CHAIN_APPROX_SIMPLE のどちらかで、Teh-Chin 系は出していない。どちらも一覧の外なら OCVU_STATUS_INVALID_ARGUMENT を返す。points_capacity と counts_capacity はどちらも配列の要素数である（バイト数でも点数でもない）—— 点 1 つにつき x と y の 2 要素を使う。どちらかが足りないときは、どちらの配列にも 1 バイトも書かずに OCVU_STATUS_BUFFER_TOO_SMALL を返し、out_contour_count に必要な輪郭の本数を、out_total_points に必要な点の総数を入れる（呼ぶ側はそれで確保し直して呼び直せる）。容量が 0 のときだけ対応する配列は NULL でよく、両方を 0 と NULL にした呼び出しが必要な大きさの問い合わせになる。容量が 1 以上なのに配列が NULL なら OCVU_STATUS_NULL_POINTER。1 本も見つからないのは誤りではない —— OCVU_STATUS_OK を返して両方に 0 を入れる。out_contour_count か out_total_points が NULL なら他の何より先に OCVU_STATUS_NULL_POINTER を返す。NULL でないほうにはその時点で 0 を書き、両方が通ったあとはどの失敗経路でも両方に 0 を書く。階層（どの輪郭がどの輪郭の内側にあるか）は返さない。handle が無効なら OCVU_STATUS_INVALID_HANDLE。OpenCV が例外を投げた場合は OCVU_STATUS_OPENCV_ERROR を返す。buffer の所有権は最初から最後まで呼ぶ側にある。 */
OCVU_API ocvu_status ocvu_find_contours(ocvu_mat_handle src, int32_t mode, int32_t method, float* out_points, int32_t points_capacity, int32_t* out_counts, int32_t counts_capacity, int32_t* out_contour_count, int32_t* out_total_points);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* OCVU_IMGPROC_H */
