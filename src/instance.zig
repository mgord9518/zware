const std = @import("std");
const common = @import("common.zig");
const Function = @import("function.zig").Function;
const Module = @import("module.zig").Module;
const Store = @import("store.zig").ArrayListStore;
const Memory = @import("memory.zig").Memory;
const Table = @import("table.zig").Table;
const Interpreter = @import("interpreter.zig").Interpreter;
const ArrayList = std.ArrayList;

const InterpreterOptions = struct {
    operand_stack_size: comptime_int = 64 * 1024,
    control_stack_size: comptime_int = 64 * 1024,
    label_stack_size: comptime_int = 64 * 1024,
};

// Instance
//
// An Instance represents the runtime instantiation of a particular module.
//
// It contains:
//      - a copy of the module it is an instance of
//      - a pointer to the Store shared amongst modules
//      - `memaddrs`: a set of addresses in the store to map a modules
//        definitions to those in the store
//      - `tableaddrs`: as per `memaddrs` but for tables
//      - `globaladdrs`: as per `memaddrs` but for globals
pub const Instance = struct {
    module: Module,
    store: *Store,
    funcaddrs: ArrayList(usize),
    memaddrs: ArrayList(usize),
    tableaddrs: ArrayList(usize),
    globaladdrs: ArrayList(usize),

    pub fn func(self: *Instance, index: usize) !Function {
        if (index >= self.funcaddrs.items.len) return error.FunctionIndexOutOfBounds;
        const handle = self.funcaddrs.items[index];
        return try self.store.function(handle);
    }

    pub fn funcHandle(self: *Instance, index: usize) !usize {
        if (index >= self.funcaddrs.items.len) return error.FunctionIndexOutOfBounds;
        return self.funcaddrs.items[index];
    }

    // Lookup a memory in store via the modules index
    pub fn memory(self: *Instance, index: usize) !*Memory {
        // TODO: with a verified program we shouldn't need to check this
        if (index >= self.memaddrs.items.len) return error.MemoryIndexOutOfBounds;
        const handle = self.memaddrs.items[index];
        return try self.store.memory(handle);
    }

    pub fn table(self: *Instance, index: usize) !*Table {
        // TODO: with a verified program we shouldn't need to check this
        if (index >= self.tableaddrs.items.len) return error.TableIndexOutOfBounds;
        const handle = self.tableaddrs.items[index];
        return try self.store.table(handle);
    }

    pub fn global(self: *Instance, index: usize) !*u64 {
        if (index >= self.globaladdrs.items.len) return error.GlobalIndexOutOfBounds;
        const handle = self.globaladdrs.items[index];
        return try self.store.global(handle);
    }

    // invoke:
    //  1. Lookup our function by name with getExport
    //  2. Get the function type signature
    //  3. Check that the incoming arguments in `args` match the function signature
    //  4. Check that the return type in `Result` matches the function signature
    //  5. Get the code for our function
    //  6. Set up the stacks (operand stack, control stack)
    //  7. Push a control frame and our parameters
    //  8. Execute our function
    //  9. Pop our result and return it
    pub fn invoke(self: *Instance, name: []const u8, args: anytype, comptime Result: type, comptime options: InterpreterOptions) !Result {
        // 1.
        const index = try self.module.getExport(.Func, name);
        if (index >= self.module.functions.list.items.len) return error.FuncIndexExceedsTypesLength;

        const function = self.module.functions.list.items[index];

        // 2.
        const func_type = self.module.types.list.items[function.typeidx];
        const params = self.module.value_types.list.items[func_type.params_offset .. func_type.params_offset + func_type.params_count];
        const results = self.module.value_types.list.items[func_type.results_offset .. func_type.results_offset + func_type.results_count];

        if (params.len != args.len) return error.ParamCountMismatch;

        // 3. check the types of params
        inline for (args) |arg, i| {
            if (params[i] != common.toValueType(@TypeOf(arg))) return error.ParamTypeMismatch;
        }

        // 4. check the result type
        if (results.len > 1) return error.OnlySingleReturnValueSupported;
        if (Result != void and results.len == 1) {
            if (results[0] != common.toValueType(Result)) return error.ResultTypeMismatch;
        }

        // 5. get the function bytecode
        const code = self.module.codes.list.items[index];

        // 6. set up our stacks
        var op_stack_mem: [options.operand_stack_size]u64 = [_]u64{0} ** options.operand_stack_size;
        var frame_stack_mem: [options.control_stack_size]Interpreter.Frame = [_]Interpreter.Frame{undefined} ** options.control_stack_size;
        var label_stack_mem: [options.label_stack_size]Interpreter.Label = [_]Interpreter.Label{undefined} ** options.control_stack_size;
        var interp = Interpreter.init(op_stack_mem[0..], frame_stack_mem[0..], label_stack_mem[0..], self);

        // I think everything below here should probably live in interpret

        const locals_start = interp.op_stack.len;

        // 7b. push params
        inline for (args) |arg, i| {
            try interp.pushOperand(@TypeOf(arg), arg);
        }

        // 7c. push (i.e. make space for) locals
        var i: usize = 0;
        while (i < code.locals_count) : (i += 1) {
            try interp.pushOperand(u64, 0);
        }

        // 7a. push control frame
        try interp.pushFrame(Interpreter.Frame{
            .op_stack_len = locals_start,
            .label_stack_len = interp.label_stack.len,
            .return_arity = results.len,
        }, code.locals_count + params.len);

        // 7a.2. push label for our implicit function block. We know we don't have
        // any code to execute after calling invoke, but we will need to
        // pop a Label
        try interp.pushLabel(Interpreter.Label{
            .return_arity = results.len,
            .op_stack_len = locals_start,
            .continuation = code.code[0..0],
        });

        // 8. Execute our function
        try interp.invoke(code.code);

        // 9.
        if (Result == void) return;
        return try interp.popOperand(Result);
    }

    // invokeDynamic
    //
    // Similar to invoke, but without some type checking
    pub fn invokeDynamic(self: *Instance, name: []const u8, in: []u64, out: []u64, comptime options: InterpreterOptions) !void {
        // 1.
        const index = try self.module.getExport(.Func, name);
        if (index >= self.module.functions.list.items.len) return error.FuncIndexExceedsTypesLength;

        // const function = self.module.functions.list.items[index];
        const function = try self.func(index);

        switch (function) {
            .function => |f| {
                // const func_type = self.module.types.list.items[function.typeidx];
                // const params = self.module.value_types.list.items[func_type.params_offset .. func_type.params_offset + func_type.params_count];
                // const results = self.module.value_types.list.items[func_type.results_offset .. func_type.results_offset + func_type.results_count];
                if (f.params.len != in.len) return error.ParamCountMismatch;
                if (f.results.len > 1) return error.OnlySingleReturnValueSupported;

                // 6. set up our stacks
                var op_stack_mem: [options.operand_stack_size]u64 = [_]u64{0} ** options.operand_stack_size;
                var frame_stack_mem: [options.control_stack_size]Interpreter.Frame = [_]Interpreter.Frame{undefined} ** options.control_stack_size;
                var label_stack_mem: [options.label_stack_size]Interpreter.Label = [_]Interpreter.Label{undefined} ** options.control_stack_size;
                var interp = Interpreter.init(op_stack_mem[0..], frame_stack_mem[0..], label_stack_mem[0..], self);

                const locals_start = interp.op_stack.len;

                // 7b. push params
                for (in) |arg, i| {
                    try interp.pushOperand(u64, arg);
                }

                // 7c. push (i.e. make space for) locals
                var i: usize = 0;
                while (i < f.locals_count) : (i += 1) {
                    try interp.pushOperand(u64, 0);
                }

                // 7a. push control frame
                try interp.pushFrame(Interpreter.Frame{
                    .op_stack_len = locals_start,
                    .label_stack_len = interp.label_stack.len,
                    .return_arity = f.results.len,
                }, f.locals_count + f.params.len);

                // 7a.2. push label for our implicit function block. We know we don't have
                // any code to execute after calling invoke, but we will need to
                // pop a Label
                try interp.pushLabel(Interpreter.Label{
                    .return_arity = f.results.len,
                    .op_stack_len = locals_start,
                    .continuation = f.code[0..0],
                });

                // 8. Execute our function
                try interp.invoke(f.code);

                // 9.
                for (out) |o, out_index| {
                    out[out_index] = try interp.popOperand(u64);
                }
            },
            .host_function => |host_func| {
                // std.debug.warn()
                return error.InvokeDynamicHostFunctionNotImplemented;
            },
        }
    }

    pub fn invokeExpression(self: *Instance, expr: []const u8, comptime Result: type, comptime options: InterpreterOptions) !Result {
        var op_stack_mem: [options.operand_stack_size]u64 = [_]u64{0} ** options.operand_stack_size;
        var frame_stack_mem: [options.control_stack_size]Interpreter.Frame = [_]Interpreter.Frame{undefined} ** options.control_stack_size;
        var label_stack_mem: [options.label_stack_size]Interpreter.Label = [_]Interpreter.Label{undefined} ** options.control_stack_size;
        var interp = Interpreter.init(op_stack_mem[0..], frame_stack_mem[0..], label_stack_mem[0..], self);

        const locals_start = interp.op_stack.len;

        try interp.pushFrame(Interpreter.Frame{
            .op_stack_len = locals_start,
            .label_stack_len = interp.label_stack.len,
            .return_arity = 1,
        }, 0);

        try interp.pushLabel(Interpreter.Label{
            .return_arity = 1,
            .op_stack_len = locals_start,
            .continuation = expr[0..0],
        });

        try interp.invoke(expr);

        switch (Result) {
            u64 => return try interp.popAnyOperand(),
            else => return try interp.popOperand(Result),
        }
    }
};