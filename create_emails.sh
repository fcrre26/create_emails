#!/bin/bash

# 配置文件路径
config_file="$HOME/.email_config"

# 默认值
default_domain_suffix=""
default_smtp_host=""
default_recipient_email="" # 收件邮箱默认值

# 读取保存的配置
if [ -f "$config_file" ]; then
    # 使用 grep 查找并赋值，如果行不存在，变量会是空的
    # 使用 ^keyword= 确保匹配行的开头，避免匹配包含 keyword 的其他行
    default_domain_suffix=$(grep "^domain_suffix=" "$config_file" | cut -d '=' -f 2)
    default_smtp_host=$(grep "^smtp_host=" "$config_file" | cut -d '=' -f 2)
    default_recipient_email=$(grep "^recipient_email=" "$config_file" | cut -d '=' -f 2) # 读取收件邮箱
fi

# 交互式输入配置信息
# 使用默认值，如果用户输入为空则使用配置文件中的值
read -p "请输入邮箱后缀（例如yourdomain.com，默认为 $default_domain_suffix）：" input_domain_suffix
domain_suffix=${input_domain_suffix:-$default_domain_suffix}

read -p "请输入SMTP服务器域名（需与证书一致，默认为 $default_smtp_host）：" input_smtp_host
smtp_host=${input_smtp_host:-$default_smtp_host}

# 收件邮箱地址输入，并使用默认值
read -p "请输入收件邮箱地址（默认为 $default_recipient_email）：" input_recipient_email
recipient_email=${input_recipient_email:-$default_recipient_email}


# 检查关键信息是否已设置
if [ -z "$domain_suffix" ]; then
    echo "错误：邮箱后缀未设置，请提供一个有效的后缀！"
    exit 1
fi
if [ -z "$smtp_host" ]; then
    echo "错误：SMTP服务器域名未设置，请提供一个有效的域名！"
    exit 1
fi
if [ -z "$recipient_email" ]; then
    echo "错误：收件邮箱地址未设置，请提供一个有效的地址！"
    exit 1
fi


# 保存配置到配置文件 (覆盖写入，确保每行一个 key=value)
# 注意：这里使用 cat heredoc 确保写入格式正确
cat > "$config_file" << EOF
domain_suffix=$domain_suffix
smtp_host=$smtp_host
recipient_email=$recipient_email
EOF

echo "配置信息已保存到 $config_file"


# 密码输入，回车自动生成 (这个密码将用于所有生成的邮箱账户)
# 这个密码是每次运行都需要输入的，没有持久化需求
read -p "请输入要创建的邮箱账户的密码（直接回车自动生成）：" password
if [ -z "$password" ]; then
    password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
    echo "生成的密码为：$password"
fi

# 设置输出文件
# 文件名加入时间戳，避免覆盖之前生成的结果
output_file="email_list_$(date +%Y%m%d_%H%M%S).txt"
# 创建一个临时文件用于在并行模式下记录输出
output_file_tmp="${output_file}.tmp"
> "$output_file_tmp" # 清空或创建临时文件


# 在容器内部创建邮箱账户
read -p "请输入要生成的邮箱数量：" count

# 检查数量是否有效
if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    echo "错误：请输入一个有效的数字作为数量！"
    exit 1
fi
if [ "$count" -le 0 ]; then
    echo "错误：生成数量必须大于 0！"
    exit 1
fi


# 容器名称，请根据你的实际情况确认
# 根据原脚本和日志，创建邮箱的容器应该是 1Panel-maddy-mail-iHBZ
maddy_container="1Panel-maddy-mail-iHBZ"

# 检查容器是否存在且正在运行
if ! docker ps --filter "name=${maddy_container}" --filter "status=running" -q > /dev/null; then
    echo "错误：Maddy 容器 '$maddy_container' 未找到或未运行！请确认容器名称和状态。"
    exit 1
fi

# === 开始多线程批量创建 ===

# 设置最大并行任务数量 (根据服务器的CPU核心数、内存等资源进行调整)
# 建议不要超过CPU核心数的2倍
MAX_JOBS=20

echo "开始批量创建 ${count} 个邮箱账号 (最大并行任务数: ${MAX_JOBS})..."

# 使用一个数组来跟踪正在运行的后台任务的PID
declare -a pids

for ((i=1; i<=count; i++)); do
    username_length=$(shuf -i 6-8 -n 1)
    username=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w "$username_length" | head -n 1)
    full_email="${username}@${domain_suffix}"

    # 使用 docker exec 在容器内部执行 maddy creds create 命令，通过 -p 参数传递密码
    # 使用 & 符号将命令放到后台执行
    # 这里使用 -it 参数，如果遇到 TTY 错误，可以尝试去掉 -t 或 -it
    docker exec -it "$maddy_container" maddy creds create "${full_email}" -p "${password}" &

    # 将后台进程的PID添加到数组
    pids+=($!)

    # 将生成的账号和使用的密码先记录到临时文件 (在启动后台任务后立即记录)
    echo "${full_email}----${password}----587" >> "$output_file_tmp"

    # 检查当前正在运行的后台任务数量
    # 如果后台任务数量达到或超过 MAX_JOBS，等待部分任务完成
    while (( ${#pids[@]} >= MAX_JOBS )); do
        # 移除已经完成的后台任务的PID
        for pid in "${!pids[@]}"; do
            # kill -0 PID 检查进程是否存在而不发送信号
            if ! kill -0 ${pids[pid]} 2>/dev/null; then
                unset pids[pid]
            fi
        done

        # 如果清理后任务数量仍然达到上限，等待任意一个后台任务完成
        if (( ${#pids[@]} >= MAX_JOBS )); then
            # wait -n 等待 pids 数组中的任意一个任务完成 (需要 Bash 4.3+ )
            # 如果 Bash 版本较低，可以考虑简单的 sleep 几秒，或使用其他并发控制方法
            wait -n "${pids[@]}" 2>/dev/null # 添加 2>/dev/null 隐藏 wait -n 在没有任务时可能出现的错误
             # 再次清理已完成的任务PID
             for pid in "${!pids[@]}"; do
                if ! kill -0 ${pids[pid]} 2>/dev/null; then
                    unset pids[pid]
                fi
            done
        fi
    done

    # 可以选择性地打印进度 (注意这里是提交任务的进度)
    if (( i % 100 == 0 )); then
         echo "进度: 已提交 $i/$count 个账户创建任务到后台..."
    fi

done

# 等待所有剩余的后台任务完成
echo "所有创建任务已提交。等待后台任务完成..."
wait ${pids[@]} 2>/dev/null # 等待 pids 数组中剩余的所有任务完成

echo "批量创建邮箱账号后台任务已完成。"

# 将临时文件内容排序（可选）并追加到最终输出文件
# sort "$output_file_tmp" >> "$output_file" # 如果需要按字母排序
cat "$output_file_tmp" >> "$output_file" # 直接追加
rm "$output_file_tmp" # 删除临时文件

echo "生成的账号列表已保存到 $(pwd)/$output_file"

# === 批量创建结束 ===


# 固定发信账号和密码 (这部分是用于发送邮件的，保持不变)
# 假设 msmtp 使用的账号和密码也是固定或从其他地方获取的
sender_email="qcxfetp@19861019.xyz"
sender_password="q0BFHpXn"

# 配置msmtp，写入固定账号和密码 (这部分是用于发送邮件的，保持不变)
# msmtp 的 host 现在从 config_file 读取的 $smtp_host 获取
msmtp_config="$HOME/.msmtprc"
cat > "$msmtp_config" << EOF
account default
host $smtp_host
port 587
auth on
user $sender_email
password $sender_password
from $sender_email
tls on
tls_starttls on
logfile ~/.msmtp.log
EOF

chmod 600 "$msmtp_config"

# 检查输出文件是否存在且不为空，再发送邮件
if [ -s "$output_file" ]; then
    echo "准备发送邮件..."
    # 发送带附件的邮件（MIME格式，纯msmtp）(这部分是用于发送邮件的，保持不变)
    boundary="ZZ_$(date +%s)_ZZ"
    {
        echo "To: $recipient_email"
        echo "From: $sender_email"
        echo "Subject: 邮箱列表"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
        echo
        echo "--$boundary"
        echo "Content-Type: text/plain; charset=utf-8"
        echo
        echo "请查收附件中的邮箱列表。"
        echo
        echo "--$boundary"
        echo "Content-Type: text/plain; name=\"email_list.txt\""
        echo "Content-Transfer-Encoding: base64"
        echo "Content-Disposition: attachment; filename=\"email_list.txt\""
        echo
        base64 "$output_file"
        echo "--$boundary--"
    } | msmtp -t

    echo "邮件已发送到 $recipient_email（附件方式）"
else
    echo "输出文件 $output_file 为空，跳过发送邮件。"
fi

echo "脚本执行完毕。"
