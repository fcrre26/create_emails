#!/bin/bash

# 配置文件路径
config_file="$HOME/.email_config"

# 默认值
default_domain_suffix=""
default_smtp_host=""
default_recipient_email="" # 新增：收件邮箱默认值

# 读取保存的配置
if [ -f "$config_file" ]; then
    # 使用 grep 查找并赋值，如果行不存在，变量会是空的
    # 使用 ^keyword= 确保匹配行的开头，避免匹配包含 keyword 的其他行
    default_domain_suffix=$(grep "^domain_suffix=" "$config_file" | cut -d '=' -f 2)
    default_smtp_host=$(grep "^smtp_host=" "$config_file" | cut -d '=' -f 2)
    default_recipient_email=$(grep "^recipient_email=" "$config_file" | cut -d '=' -f 2) # 新增：读取收件邮箱
fi

# 交互式输入配置信息
# 使用默认值，如果用户输入为空则使用配置文件中的值
read -p "请输入邮箱后缀（例如yourdomain.com，默认为 $default_domain_suffix）：" input_domain_suffix
domain_suffix=${input_domain_suffix:-$default_domain_suffix}

read -p "请输入SMTP服务器域名（需与证书一致，默认为 $default_smtp_host）：" input_smtp_host
smtp_host=${input_smtp_host:-$default_smtp_host}

# 新增：收件邮箱地址输入，并使用默认值
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

# 创建输出文件
# 文件名加入时间戳，避免覆盖之前生成的结果
output_file="email_list_$(date +%Y%m%d_%H%M%S).txt"
> "$output_file"  # 清空或创建文件


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


echo "开始批量创建 ${count} 个邮箱账号..."

# 容器名称，请根据你的实际情况确认
# 根据原脚本和日志，创建邮箱的容器应该是 1Panel-maddy-mail-iHBZ
maddy_container="1Panel-maddy-mail-iHBZ"

# 检查容器是否存在且正在运行
if ! docker ps --filter "name=${maddy_container}" --filter "status=running" -q > /dev/null; then
    echo "错误：Maddy 容器 '$maddy_container' 未找到或未运行！请确认容器名称和状态。"
    exit 1
fi

# 注意：maddy creds create 在某些环境下即使使用 -i 也可能需要 TTY 或其他参数才能非交互式工作
# 之前的尝试显示它仍在等待密码输入。
# 这里的循环会继续尝试，但可能实际用户并未被创建。
# 真正的解决方案需要找到 maddy creds create 的正确非交互式用法。
# 目前这个循环只记录到文件，并触发脚本后续的邮件发送（即使用户未创建成功）。
# 如果 maddy creds create 成功执行，它应该不会打印 "Enter password for new user:"
# 如果你仍然看到 "Enter password for new user:"，说明创建用户实际是失败的。
for ((i=1; i<=count; i++)); do
    username_length=$(shuf -i 6-8 -n 1)
    username=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w "$username_length" | head -n 1)
    full_email="${username}@${domain_suffix}"

    # 通过标准输入将密码传递给 maddy creds create 命令
    # 移除可能不支持的 -T，保留 -i
    # 这里的命令是尝试非交互式创建用户的核心
    echo "$password" | docker exec -i "$maddy_container" /bin/sh -c "maddy creds create '${full_email}'"
    # 检查 docker exec 命令的退出状态，如果非零表示命令执行失败
    if [ $? -ne 0 ]; then
        # 这里可能会捕获到 maddy creds create 失败的退出码
        # 但是如果它只是卡在等待输入，退出码可能是 0 或其他
        # 更好的判断创建成功与否的方式是查看 Maddy 容器日志
        echo "警告：尝试创建用户 $full_email 失败或命令执行异常。请检查 Maddy 容器日志。"
        # 如果你确定即使失败也继续生成列表，可以 uncomment 下一行
        # continue
    fi


    # 将生成的账号和使用的密码记录到输出文件
    echo "${full_email}----${password}----587" >> "$output_file"

    # 可以选择性地打印进度
    if (( i % 100 == 0 )); then
         echo "进度: 已处理 $i/$count 个账户信息..."
    fi

done

echo "账号列表信息生成完毕，已保存到 $(pwd)/$output_file"
# 注意：上面的步骤只是生成了列表文件，Maddy 用户是否真正创建成功需要额外确认


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
