(module
  ;; sum: adds two i32 values
  (func $sum (export "sum") (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add)
  
  ;; add: alias for sum (some conventions use "add")
  (func $add (export "add") (param $x i32) (param $y i32) (result i32)
    local.get $x
    local.get $y
    i32.add)
  
  ;; multiply: multiplies two i32 values
  (func $multiply (export "multiply") (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.mul))
