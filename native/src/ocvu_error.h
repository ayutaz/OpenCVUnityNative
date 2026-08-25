#ifndef OCVU_ERROR_H
#define OCVU_ERROR_H

#include "opencv_unity_native.h"

namespace ocvu {

/* last-error を設定し、渡された status をそのまま返す。 */
ocvu_status set_last_error(ocvu_status status, const char* message);

void clear_last_error();

}  // namespace ocvu

#endif  // OCVU_ERROR_H
