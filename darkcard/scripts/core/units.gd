class_name Units

# 定点缩放的唯一来源。
# 内部一律用整数运算：血 1 点 = 100，运 1 点 = 10。
# 之前这些数字散落在 core / ui / ai 三处共 20 多个位置，
# 改一个缩放要满工程搜索，属于典型的魔法数字技术债。
const HP := 100
const YUN := 10
const PERCENT := 100
