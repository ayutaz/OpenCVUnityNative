#ifndef OCVU_TEST_PLATFORM_H
#define OCVU_TEST_PLATFORM_H

namespace ocvu_test {

/*
 * クラッシュ時にモーダルダイアログを出さないようにする。
 * これを呼ばないと、Windows では異常終了が Windows Error Reporting の
 * ダイアログで停止し、CI とエージェントのループがタイムアウトまで固まる。
 * テストプロセスの main で最初に呼ぶこと。
 */
void suppress_crash_dialogs();

}  // namespace ocvu_test

#endif  // OCVU_TEST_PLATFORM_H
