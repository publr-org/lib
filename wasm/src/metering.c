/* What is left of an execution environment's instruction limit, as the interpreter wrote it
 * when it last returned or handed over to a host function. WAMR exports the setter only. */
#include "wasm_exec_env.h"

int
publr_wasm_instructions_left(WASMExecEnv *exec_env)
{
    return exec_env->instructions_to_execute;
}
