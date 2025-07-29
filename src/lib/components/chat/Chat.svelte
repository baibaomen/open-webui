<script lang="ts">
	import { v4 as uuidv4 } from 'uuid';
	import { toast } from 'svelte-sonner';
	import mermaid from 'mermaid';
	import { PaneGroup, Pane, PaneResizer } from 'paneforge';

	import { getContext, onDestroy, onMount, tick } from 'svelte';
	const i18n: Writable<i18nType> = getContext('i18n');

	import { goto } from '$app/navigation';
	import { page } from '$app/stores';

	import { get, type Unsubscriber, type Writable } from 'svelte/store';
	import type { i18n as i18nType } from 'i18next';
	import { WEBUI_BASE_URL } from '$lib/constants';

	import {
		chatId,
		chats,
		config,
		type Model,
		models,
		tags as allTags,
		settings,
		showSidebar,
		WEBUI_NAME,
		banners,
		user,
		socket,
		showControls,
		showCallOverlay,
		currentChatPage,
		temporaryChatEnabled,
		mobile,
		showOverview,
		chatTitle,
		showArtifacts,
		tools,
		toolServers
	} from '$lib/stores';
	import {
		convertMessagesToHistory,
		copyToClipboard,
		getMessageContentParts,
		createMessagesList,
		extractSentencesForAudio,
		promptTemplate,
		splitStream,
		sleep,
		removeDetails,
		getPromptVariables,
		processDetails
	} from '$lib/utils';

	import { generateChatCompletion } from '$lib/apis/ollama';
	import {
		addTagById,
		createNewChat,
		deleteTagById,
		deleteTagsById,
		getAllTags,
		getChatById,
		getChatList,
		getTagsById,
		updateChatById
	} from '$lib/apis/chats';
	import { generateOpenAIChatCompletion } from '$lib/apis/openai';
	import { processWeb, processWebSearch, processYoutubeVideo } from '$lib/apis/retrieval';
	import { createOpenAITextStream } from '$lib/apis/streaming';
	import { queryMemory } from '$lib/apis/memories';
	import { getAndUpdateUserLocation, getUserSettings } from '$lib/apis/users';
	import {
		chatCompleted,
		generateQueries,
		chatAction,
		generateMoACompletion,
		stopTask,
		getTaskIdsByChatId
	} from '$lib/apis';
	import { getTools } from '$lib/apis/tools';

	import Banner from '../common/Banner.svelte';
	import MessageInput from '$lib/components/chat/MessageInput.svelte';
	import Messages from '$lib/components/chat/Messages.svelte';
	import Navbar from '$lib/components/chat/Navbar.svelte';
	import ChatControls from './ChatControls.svelte';
	import EventConfirmDialog from '../common/ConfirmDialog.svelte';
	import Placeholder from './Placeholder.svelte';
	import NotificationToast from '../NotificationToast.svelte';
	import Spinner from '../common/Spinner.svelte';

	export let chatIdProp = '';

	let loading = true;

	const eventTarget = new EventTarget();
	let controlPane;
	let controlPaneComponent;

	let autoScroll = true;
	let processing = '';
	let messagesContainerElement: HTMLDivElement;

	let navbarElement;

	let showEventConfirmation = false;
	let eventConfirmationTitle = '';
	let eventConfirmationMessage = '';
	let eventConfirmationInput = false;
	let eventConfirmationInputPlaceholder = '';
	let eventConfirmationInputValue = '';
	let eventCallback = null;

	// 轮播广告状态
	let currentSlide = 0;
	let slideInterval: NodeJS.Timeout | undefined;
	const totalSlides = 4;

	// 即将推出提示函数
	const showComingSoon = () => {
		alert('即将推出，敬请期待');
	};

	// GIF动画重播函数
	const replayGif = (imgElement: HTMLImageElement) => {
		// 使用更平滑的方法：保存当前src，然后用新的时间戳重新设置
		const originalSrc = imgElement.src.split('?')[0]; // 移除之前的时间戳参数
		const timestamp = new Date().getTime();
		
		// 创建一个新的Image对象预加载，然后无缝切换
		const tempImg = new Image();
		tempImg.onload = () => {
			imgElement.src = originalSrc + '?t=' + timestamp;
		};
		tempImg.src = originalSrc + '?t=' + timestamp;
	};

	// 处理GIF图片的鼠标事件
	const handleGifHover = (event: MouseEvent) => {
		const imgElement = event.target as HTMLImageElement;
		replayGif(imgElement);
	};

	const handleGifClick = (event: MouseEvent) => {
		const imgElement = event.target as HTMLImageElement;
		replayGif(imgElement);
	};



	// 轮播控制函数
	const startCarousel = () => {
		if (slideInterval) {
			clearInterval(slideInterval);
		}
		slideInterval = setInterval(() => {
			currentSlide = (currentSlide + 1) % totalSlides;
		}, 5000000);
	};

	const pauseCarousel = () => {
		if (slideInterval) {
			clearInterval(slideInterval);
		}
	};

	const nextSlide = () => {
		currentSlide = (currentSlide + 1) % totalSlides;
		startCarousel();
	};

	const prevSlide = () => {
		currentSlide = (currentSlide - 1 + totalSlides) % totalSlides;
		startCarousel();
	};

	// AI助手DPI设置函数
	const setAIAssistantDPI = () => {
		const screenWidth = window.innerWidth;
		let dpiScale = 1;
		
		if (screenWidth <= 1366) {
			if(window.devicePixelRatio >= 2) {
				dpiScale = 0.6;
			}	else {
				dpiScale = 0.7;
			}
		} else if (screenWidth >= 1920) {
			dpiScale = 1;
		} else {
			// 1366 到 1920 之间线性插值
			dpiScale = 0.8 + ((screenWidth - 1366) / (1920 - 1366)) * 0.2;
		}
		
		setTimeout(() => {
			const aiAssistantElements = document.querySelectorAll('.ai-assistant');
			aiAssistantElements.forEach(element => {
				element.style.transform = `scale(${dpiScale})`;
				element.style.transformOrigin = 'center center';
				element.style.height = `${100 / dpiScale}%`;
			});
		}, 100);
	};

	// 窗口大小变化处理函数
	const handleResize = () => {
		setAIAssistantDPI();
	};

	// 创建新会话并选择指定模型
	const createNewChatWithModel = async (modelName: string) => {
		try {
			// 查找指定名称的模型
			const targetModel = $models.find(m => m.name === modelName);
			let selectedModelId = '';
			
			if (targetModel) {
				selectedModelId = targetModel.id;
				console.log(`找到模型 "${modelName}":`, targetModel);
			} else {
				// 如果没有找到指定模型，使用默认模型
				const availableModels = $models.filter((m) => !((m?.info?.meta as any)?.hidden ?? false));
				if (availableModels.length > 0) {
					selectedModelId = availableModels[0].id;
					console.log(`未找到模型 "${modelName}"，使用默认模型:`, availableModels[0]);
				} else {
					toast.error('没有可用的模型');
					return;
				}
			}

			// 创建新会话
			const newChat = await createNewChat(localStorage.token, {
				title: '新会话',
				models: [selectedModelId],
				system: $settings?.system ?? undefined,
				params: {},
				history: {
					messages: {},
					currentId: null
				},
				messages: [],
				tags: [],
				timestamp: Date.now()
			});

			if (newChat) {
				// 更新当前选择的模型
				selectedModels = [selectedModelId];
				
				// 跳转到新创建的会话
				await goto(`/c/${newChat.id}`);
				
				// 设置当前会话ID
				chatId.set(newChat.id);
				
				// 刷新会话列表
				currentChatPage.set(1);
				await chats.set(await getChatList(localStorage.token, $currentChatPage));
				
				toast.success(`新会话已创建`);
			}
		} catch (error) {
			console.error('创建新会话失败:', error);
			toast.error('创建新会话失败，请重试');
		}
	};

	let chatIdUnsubscriber: Unsubscriber | undefined;

	let selectedModels = [''];
	let atSelectedModel: Model | undefined;
	let selectedModelIds = [];
	$: selectedModelIds = atSelectedModel !== undefined ? [atSelectedModel.id] : selectedModels;

	let selectedToolIds = [];
	let selectedFilterIds = [];
	let imageGenerationEnabled = false;
	let webSearchEnabled = false;
	let codeInterpreterEnabled = false;

	let chat = null;
	let tags = [];

	let history = {
		messages: {},
		currentId: null
	};

	let taskIds = null;

	// Chat Input
	let prompt = '';
	let chatFiles = [];
	let files = [];
	let params = {};

	$: if (chatIdProp) {
		(async () => {
			loading = true;

			prompt = '';
			files = [];
			selectedToolIds = [];
			selectedFilterIds = [];
			webSearchEnabled = false;
			imageGenerationEnabled = false;

			if (localStorage.getItem(`chat-input${chatIdProp ? `-${chatIdProp}` : ''}`)) {
				try {
					const input = JSON.parse(
						localStorage.getItem(`chat-input${chatIdProp ? `-${chatIdProp}` : ''}`)
					);

					if (!$temporaryChatEnabled) {
						prompt = input.prompt;
						files = input.files;
						selectedToolIds = input.selectedToolIds;
						selectedFilterIds = input.selectedFilterIds;
						webSearchEnabled = input.webSearchEnabled;
						imageGenerationEnabled = input.imageGenerationEnabled;
						codeInterpreterEnabled = input.codeInterpreterEnabled;
					}
				} catch (e) {}
			}

			if (chatIdProp && (await loadChat())) {
				await tick();
				loading = false;
				window.setTimeout(() => scrollToBottom(), 0);
				const chatInput = document.getElementById('chat-input');
				chatInput?.focus();
			} else {
				await goto('/');
			}
		})();
	}

	$: if (selectedModels && chatIdProp !== '') {
		saveSessionSelectedModels();
	}

	const saveSessionSelectedModels = () => {
		if (selectedModels.length === 0 || (selectedModels.length === 1 && selectedModels[0] === '')) {
			return;
		}
		sessionStorage.selectedModels = JSON.stringify(selectedModels);
		console.log('saveSessionSelectedModels', selectedModels, sessionStorage.selectedModels);
	};

	$: if (selectedModels) {
		setToolIds();
		setFilterIds();
	}

	$: if (atSelectedModel || selectedModels) {
		setToolIds();
		setFilterIds();
	}

	const setToolIds = async () => {
		if (!$tools) {
			tools.set(await getTools(localStorage.token));
		}

		if (selectedModels.length !== 1 && !atSelectedModel) {
			return;
		}

		const model = atSelectedModel ?? $models.find((m) => m.id === selectedModels[0]);
		if (model) {
			selectedToolIds = [
				...new Set(
					[...selectedToolIds, ...(model?.info?.meta?.toolIds ?? [])].filter((id) =>
						$tools.find((t) => t.id === id)
					)
				)
			];
		}
	};

	const setFilterIds = async () => {
		if (selectedModels.length !== 1 && !atSelectedModel) {
			selectedFilterIds = [];
		}
	};

	const showMessage = async (message) => {
		const _chatId = JSON.parse(JSON.stringify($chatId));
		let _messageId = JSON.parse(JSON.stringify(message.id));

		let messageChildrenIds = [];
		if (_messageId === null) {
			messageChildrenIds = Object.keys(history.messages).filter(
				(id) => history.messages[id].parentId === null
			);
		} else {
			messageChildrenIds = history.messages[_messageId].childrenIds;
		}

		while (messageChildrenIds.length !== 0) {
			_messageId = messageChildrenIds.at(-1);
			messageChildrenIds = history.messages[_messageId].childrenIds;
		}

		history.currentId = _messageId;

		await tick();
		await tick();
		await tick();

		if ($settings?.scrollOnBranchChange ?? true) {
			const messageElement = document.getElementById(`message-${message.id}`);
			if (messageElement) {
				messageElement.scrollIntoView({ behavior: 'smooth' });
			}
		}

		await tick();
		saveChatHandler(_chatId, history);
	};

	const chatEventHandler = async (event, cb) => {
		console.log(event);

		if (event.chat_id === $chatId) {
			await tick();
			let message = history.messages[event.message_id];

			if (message) {
				const type = event?.data?.type ?? null;
				const data = event?.data?.data ?? null;

				if (type === 'status') {
					if (message?.statusHistory) {
						message.statusHistory.push(data);
					} else {
						message.statusHistory = [data];
					}
				} else if (type === 'chat:completion') {
					chatCompletionEventHandler(data, message, event.chat_id);
				} else if (type === 'chat:message:delta' || type === 'message') {
					message.content += data.content;
				} else if (type === 'chat:message' || type === 'replace') {
					message.content = data.content;
				} else if (type === 'chat:message:files' || type === 'files') {
					message.files = data.files;
				} else if (type === 'chat:title') {
					chatTitle.set(data);
					currentChatPage.set(1);
					await chats.set(await getChatList(localStorage.token, $currentChatPage));
				} else if (type === 'chat:tags') {
					chat = await getChatById(localStorage.token, $chatId);
					allTags.set(await getAllTags(localStorage.token));
				} else if (type === 'source' || type === 'citation') {
					if (data?.type === 'code_execution') {
						// Code execution; update existing code execution by ID, or add new one.
						if (!message?.code_executions) {
							message.code_executions = [];
						}

						const existingCodeExecutionIndex = message.code_executions.findIndex(
							(execution) => execution.id === data.id
						);

						if (existingCodeExecutionIndex !== -1) {
							message.code_executions[existingCodeExecutionIndex] = data;
						} else {
							message.code_executions.push(data);
						}

						message.code_executions = message.code_executions;
					} else {
						// Regular source.
						if (message?.sources) {
							message.sources.push(data);
						} else {
							message.sources = [data];
						}
					}
				} else if (type === 'notification') {
					const toastType = data?.type ?? 'info';
					const toastContent = data?.content ?? '';

					if (toastType === 'success') {
						toast.success(toastContent);
					} else if (toastType === 'error') {
						toast.error(toastContent);
					} else if (toastType === 'warning') {
						toast.warning(toastContent);
					} else {
						toast.info(toastContent);
					}
				} else if (type === 'confirmation') {
					eventCallback = cb;

					eventConfirmationInput = false;
					showEventConfirmation = true;

					eventConfirmationTitle = data.title;
					eventConfirmationMessage = data.message;
				} else if (type === 'execute') {
					eventCallback = cb;

					try {
						// Use Function constructor to evaluate code in a safer way
						const asyncFunction = new Function(`return (async () => { ${data.code} })()`);
						const result = await asyncFunction(); // Await the result of the async function

						if (cb) {
							cb(result);
						}
					} catch (error) {
						console.error('Error executing code:', error);
					}
				} else if (type === 'input') {
					eventCallback = cb;

					eventConfirmationInput = true;
					showEventConfirmation = true;

					eventConfirmationTitle = data.title;
					eventConfirmationMessage = data.message;
					eventConfirmationInputPlaceholder = data.placeholder;
					eventConfirmationInputValue = data?.value ?? '';
				} else {
					console.log('Unknown message type', data);
				}

				history.messages[event.message_id] = message;
			}
		}
	};

	const onMessageHandler = async (event: {
		origin: string;
		data: { type: string; text: string };
	}) => {
		if (event.origin !== window.origin) {
			return;
		}

		// Replace with your iframe's origin
		if (event.data.type === 'input:prompt') {
			console.debug(event.data.text);

			const inputElement = document.getElementById('chat-input');

			if (inputElement) {
				prompt = event.data.text;
				inputElement.focus();
			}
		}

		if (event.data.type === 'action:submit') {
			console.debug(event.data.text);

			if (prompt !== '') {
				await tick();
				submitPrompt(prompt);
			}
		}

		if (event.data.type === 'input:prompt:submit') {
			console.debug(event.data.text);

			if (event.data.text !== '') {
				await tick();
				submitPrompt(event.data.text);
			}
		}
	};

	onMount(async () => {
		loading = true;
		console.log('mounted');
		window.addEventListener('message', onMessageHandler);
		$socket?.on('chat-events', chatEventHandler);

		// 启动轮播
		startCarousel();

		// 根据屏幕宽度设置AI助手界面DPI
		setAIAssistantDPI();

		// 监听窗口大小变化
		window.addEventListener('resize', handleResize);

		if (!$chatId) {
			chatIdUnsubscriber = chatId.subscribe(async (value) => {
				if (!value) {
					await tick(); // Wait for DOM updates
					await initNewChat();
				}
			});
		} else {
			if ($temporaryChatEnabled) {
				await goto('/');
			}
		}

		if (localStorage.getItem(`chat-input${chatIdProp ? `-${chatIdProp}` : ''}`)) {
			prompt = '';
			files = [];
			selectedToolIds = [];
			selectedFilterIds = [];
			webSearchEnabled = false;
			imageGenerationEnabled = false;
			codeInterpreterEnabled = false;

			try {
				const input = JSON.parse(
					localStorage.getItem(`chat-input${chatIdProp ? `-${chatIdProp}` : ''}`)
				);

				if (!$temporaryChatEnabled) {
					prompt = input.prompt;
					files = input.files;
					selectedToolIds = input.selectedToolIds;
					selectedFilterIds = input.selectedFilterIds;
					webSearchEnabled = input.webSearchEnabled;
					imageGenerationEnabled = input.imageGenerationEnabled;
					codeInterpreterEnabled = input.codeInterpreterEnabled;
				}
			} catch (e) {}
		}

		if (!chatIdProp) {
			loading = false;
			await tick();
		}

		showControls.subscribe(async (value) => {
			if (controlPane && !$mobile) {
				try {
					if (value) {
						controlPaneComponent.openPane();
					} else {
						controlPane.collapse();
					}
				} catch (e) {
					// ignore
				}
			}

			if (!value) {
				showCallOverlay.set(false);
				showOverview.set(false);
				showArtifacts.set(false);
			}
		});

		const chatInput = document.getElementById('chat-input');
		chatInput?.focus();

		chats.subscribe(() => {});
	});

	onDestroy(() => {
		chatIdUnsubscriber?.();
		window.removeEventListener('message', onMessageHandler);
		$socket?.off('chat-events', chatEventHandler);

		// 清理轮播定时器
		if (slideInterval) {
			clearInterval(slideInterval);
		}

		// 清理resize监听器
		window.removeEventListener('resize', handleResize);
	});

	// File upload functions

	const uploadGoogleDriveFile = async (fileData) => {
		console.log('Starting uploadGoogleDriveFile with:', {
			id: fileData.id,
			name: fileData.name,
			url: fileData.url,
			headers: {
				Authorization: `Bearer ${token}`
			}
		});

		// Validate input
		if (!fileData?.id || !fileData?.name || !fileData?.url || !fileData?.headers?.Authorization) {
			throw new Error('Invalid file data provided');
		}

		const tempItemId = uuidv4();
		const fileItem = {
			type: 'file',
			file: '',
			id: null,
			url: fileData.url,
			name: fileData.name,
			collection_name: '',
			status: 'uploading',
			error: '',
			itemId: tempItemId,
			size: 0
		};

		try {
			files = [...files, fileItem];
			console.log('Processing web file with URL:', fileData.url);

			// Configure fetch options with proper headers
			const fetchOptions = {
				headers: {
					Authorization: fileData.headers.Authorization,
					Accept: '*/*'
				},
				method: 'GET'
			};

			// Attempt to fetch the file
			console.log('Fetching file content from Google Drive...');
			const fileResponse = await fetch(fileData.url, fetchOptions);

			if (!fileResponse.ok) {
				const errorText = await fileResponse.text();
				throw new Error(`Failed to fetch file (${fileResponse.status}): ${errorText}`);
			}

			// Get content type from response
			const contentType = fileResponse.headers.get('content-type') || 'application/octet-stream';
			console.log('Response received with content-type:', contentType);

			// Convert response to blob
			console.log('Converting response to blob...');
			const fileBlob = await fileResponse.blob();

			if (fileBlob.size === 0) {
				throw new Error('Retrieved file is empty');
			}

			console.log('Blob created:', {
				size: fileBlob.size,
				type: fileBlob.type || contentType
			});

			// Create File object with proper MIME type
			const file = new File([fileBlob], fileData.name, {
				type: fileBlob.type || contentType
			});

			console.log('File object created:', {
				name: file.name,
				size: file.size,
				type: file.type
			});

			if (file.size === 0) {
				throw new Error('Created file is empty');
			}

			// Upload file to server
			console.log('Uploading file to server...');
			const uploadedFile = await uploadFile(localStorage.token, file);

			if (!uploadedFile) {
				throw new Error('Server returned null response for file upload');
			}

			console.log('File uploaded successfully:', uploadedFile);

			// Update file item with upload results
			fileItem.status = 'uploaded';
			fileItem.file = uploadedFile;
			fileItem.id = uploadedFile.id;
			fileItem.size = file.size;
			fileItem.collection_name = uploadedFile?.meta?.collection_name;
			fileItem.url = `${WEBUI_API_BASE_URL}/files/${uploadedFile.id}`;

			files = files;
			toast.success($i18n.t('File uploaded successfully'));
		} catch (e) {
			console.error('Error uploading file:', e);
			files = files.filter((f) => f.itemId !== tempItemId);
			toast.error(
				$i18n.t('Error uploading file: {{error}}', {
					error: e.message || 'Unknown error'
				})
			);
		}
	};

	const uploadWeb = async (url) => {
		console.log(url);

		const fileItem = {
			type: 'doc',
			name: url,
			collection_name: '',
			status: 'uploading',
			url: url,
			error: ''
		};

		try {
			files = [...files, fileItem];
			const res = await processWeb(localStorage.token, '', url);

			if (res) {
				fileItem.status = 'uploaded';
				fileItem.collection_name = res.collection_name;
				fileItem.file = {
					...res.file,
					...fileItem.file
				};

				files = files;
			}
		} catch (e) {
			// Remove the failed doc from the files array
			files = files.filter((f) => f.name !== url);
			toast.error(JSON.stringify(e));
		}
	};

	const uploadYoutubeTranscription = async (url) => {
		console.log(url);

		const fileItem = {
			type: 'doc',
			name: url,
			collection_name: '',
			status: 'uploading',
			context: 'full',
			url: url,
			error: ''
		};

		try {
			files = [...files, fileItem];
			const res = await processYoutubeVideo(localStorage.token, url);

			if (res) {
				fileItem.status = 'uploaded';
				fileItem.collection_name = res.collection_name;
				fileItem.file = {
					...res.file,
					...fileItem.file
				};
				files = files;
			}
		} catch (e) {
			// Remove the failed doc from the files array
			files = files.filter((f) => f.name !== url);
			toast.error(`${e}`);
		}
	};

	//////////////////////////
	// Web functions
	//////////////////////////

	const initNewChat = async () => {
		const availableModels = $models
			.filter((m) => !(m?.info?.meta?.hidden ?? false))
			.map((m) => m.id);

		if ($page.url.searchParams.get('models') || $page.url.searchParams.get('model')) {
			const urlModels = (
				$page.url.searchParams.get('models') ||
				$page.url.searchParams.get('model') ||
				''
			)?.split(',');

			if (urlModels.length === 1) {
				const m = $models.find((m) => m.id === urlModels[0]);
				if (!m) {
					const modelSelectorButton = document.getElementById('model-selector-0-button');
					if (modelSelectorButton) {
						modelSelectorButton.click();
						await tick();

						const modelSelectorInput = document.getElementById('model-search-input');
						if (modelSelectorInput) {
							modelSelectorInput.focus();
							modelSelectorInput.value = urlModels[0];
							modelSelectorInput.dispatchEvent(new Event('input'));
						}
					}
				} else {
					selectedModels = urlModels;
				}
			} else {
				selectedModels = urlModels;
			}

			selectedModels = selectedModels.filter((modelId) =>
				$models.map((m) => m.id).includes(modelId)
			);
		} else {
			if (sessionStorage.selectedModels) {
				selectedModels = JSON.parse(sessionStorage.selectedModels);
				sessionStorage.removeItem('selectedModels');
			} else {
				if ($settings?.models) {
					selectedModels = $settings?.models;
				} else if ($config?.default_models) {
					console.log($config?.default_models.split(',') ?? '');
					selectedModels = $config?.default_models.split(',');
				}
			}
			selectedModels = selectedModels.filter((modelId) => availableModels.includes(modelId));
		}

		if (selectedModels.length === 0 || (selectedModels.length === 1 && selectedModels[0] === '')) {
			if (availableModels.length > 0) {
				selectedModels = [availableModels?.at(0) ?? ''];
			} else {
				selectedModels = [''];
			}
		}

		await showControls.set(false);
		await showCallOverlay.set(false);
		await showOverview.set(false);
		await showArtifacts.set(false);

		if ($page.url.pathname.includes('/c/')) {
			window.history.replaceState(history.state, '', `/`);
		}

		autoScroll = true;

		await chatId.set('');
		await chatTitle.set('');

		history = {
			messages: {},
			currentId: null
		};

		chatFiles = [];
		params = {};

		if ($page.url.searchParams.get('youtube')) {
			uploadYoutubeTranscription(
				`https://www.youtube.com/watch?v=${$page.url.searchParams.get('youtube')}`
			);
		}
		if ($page.url.searchParams.get('web-search') === 'true') {
			webSearchEnabled = true;
		}

		if ($page.url.searchParams.get('image-generation') === 'true') {
			imageGenerationEnabled = true;
		}

		if ($page.url.searchParams.get('tools')) {
			selectedToolIds = $page.url.searchParams
				.get('tools')
				?.split(',')
				.map((id) => id.trim())
				.filter((id) => id);
		} else if ($page.url.searchParams.get('tool-ids')) {
			selectedToolIds = $page.url.searchParams
				.get('tool-ids')
				?.split(',')
				.map((id) => id.trim())
				.filter((id) => id);
		}

		if ($page.url.searchParams.get('call') === 'true') {
			showCallOverlay.set(true);
			showControls.set(true);
		}

		if ($page.url.searchParams.get('q')) {
			prompt = $page.url.searchParams.get('q') ?? '';

			if (prompt) {
				await tick();
				submitPrompt(prompt);
			}
		}

		selectedModels = selectedModels.map((modelId) =>
			$models.map((m) => m.id).includes(modelId) ? modelId : ''
		);

		const userSettings = await getUserSettings(localStorage.token);

		if (userSettings) {
			settings.set(userSettings.ui);
		} else {
			settings.set(JSON.parse(localStorage.getItem('settings') ?? '{}'));
		}

		const chatInput = document.getElementById('chat-input');
		setTimeout(() => chatInput?.focus(), 0);
	};

	const loadChat = async () => {
		chatId.set(chatIdProp);
		chat = await getChatById(localStorage.token, $chatId).catch(async (error) => {
			await goto('/');
			return null;
		});

		if (chat) {
			tags = await getTagsById(localStorage.token, $chatId).catch(async (error) => {
				return [];
			});

			const chatContent = chat.chat;

			if (chatContent) {
				console.log(chatContent);

				selectedModels =
					(chatContent?.models ?? undefined) !== undefined
						? chatContent.models
						: [chatContent.models ?? ''];
				history =
					(chatContent?.history ?? undefined) !== undefined
						? chatContent.history
						: convertMessagesToHistory(chatContent.messages);

				chatTitle.set(chatContent.title);

				const userSettings = await getUserSettings(localStorage.token);

				if (userSettings) {
					await settings.set(userSettings.ui);
				} else {
					await settings.set(JSON.parse(localStorage.getItem('settings') ?? '{}'));
				}

				params = chatContent?.params ?? {};
				chatFiles = chatContent?.files ?? [];

				autoScroll = true;
				await tick();

				if (history.currentId) {
					for (const message of Object.values(history.messages)) {
						if (message.role === 'assistant') {
							message.done = true;
						}
					}
				}

				const taskRes = await getTaskIdsByChatId(localStorage.token, $chatId).catch((error) => {
					return null;
				});

				if (taskRes) {
					taskIds = taskRes.task_ids;
				}

				await tick();

				return true;
			} else {
				return null;
			}
		}
	};

	const scrollToBottom = async () => {
		await tick();
		if (messagesContainerElement) {
			messagesContainerElement.scrollTop = messagesContainerElement.scrollHeight;
		}
	};
	const chatCompletedHandler = async (chatId, modelId, responseMessageId, messages) => {
		const res = await chatCompleted(localStorage.token, {
			model: modelId,
			messages: messages.map((m) => ({
				id: m.id,
				role: m.role,
				content: m.content,
				info: m.info ? m.info : undefined,
				timestamp: m.timestamp,
				...(m.usage ? { usage: m.usage } : {}),
				...(m.sources ? { sources: m.sources } : {})
			})),
			filter_ids: selectedFilterIds.length > 0 ? selectedFilterIds : undefined,
			model_item: $models.find((m) => m.id === modelId),
			chat_id: chatId,
			session_id: $socket?.id,
			id: responseMessageId
		}).catch((error) => {
			toast.error(`${error}`);
			messages.at(-1).error = { content: error };

			return null;
		});

		if (res !== null && res.messages) {
			// Update chat history with the new messages
			for (const message of res.messages) {
				if (message?.id) {
					// Add null check for message and message.id
					history.messages[message.id] = {
						...history.messages[message.id],
						...(history.messages[message.id].content !== message.content
							? { originalContent: history.messages[message.id].content }
							: {}),
						...message
					};
				}
			}
		}

		await tick();

		if ($chatId == chatId) {
			if (!$temporaryChatEnabled) {
				chat = await updateChatById(localStorage.token, chatId, {
					models: selectedModels,
					messages: messages,
					history: history,
					params: params,
					files: chatFiles
				});

				currentChatPage.set(1);
				await chats.set(await getChatList(localStorage.token, $currentChatPage));
			}
		}

		taskIds = null;
	};

	const chatActionHandler = async (chatId, actionId, modelId, responseMessageId, event = null) => {
		const messages = createMessagesList(history, responseMessageId);

		const res = await chatAction(localStorage.token, actionId, {
			model: modelId,
			messages: messages.map((m) => ({
				id: m.id,
				role: m.role,
				content: m.content,
				info: m.info ? m.info : undefined,
				timestamp: m.timestamp,
				...(m.sources ? { sources: m.sources } : {})
			})),
			...(event ? { event: event } : {}),
			model_item: $models.find((m) => m.id === modelId),
			chat_id: chatId,
			session_id: $socket?.id,
			id: responseMessageId
		}).catch((error) => {
			toast.error(`${error}`);
			messages.at(-1).error = { content: error };
			return null;
		});

		if (res !== null && res.messages) {
			// Update chat history with the new messages
			for (const message of res.messages) {
				history.messages[message.id] = {
					...history.messages[message.id],
					...(history.messages[message.id].content !== message.content
						? { originalContent: history.messages[message.id].content }
						: {}),
					...message
				};
			}
		}

		if ($chatId == chatId) {
			if (!$temporaryChatEnabled) {
				chat = await updateChatById(localStorage.token, chatId, {
					models: selectedModels,
					messages: messages,
					history: history,
					params: params,
					files: chatFiles
				});

				currentChatPage.set(1);
				await chats.set(await getChatList(localStorage.token, $currentChatPage));
			}
		}
	};

	const getChatEventEmitter = async (modelId: string, chatId: string = '') => {
		return setInterval(() => {
			$socket?.emit('usage', {
				action: 'chat',
				model: modelId,
				chat_id: chatId
			});
		}, 1000);
	};

	const createMessagePair = async (userPrompt) => {
		prompt = '';
		if (selectedModels.length === 0) {
			toast.error($i18n.t('Model not selected'));
		} else {
			const modelId = selectedModels[0];
			const model = $models.filter((m) => m.id === modelId).at(0);

			const messages = createMessagesList(history, history.currentId);
			const parentMessage = messages.length !== 0 ? messages.at(-1) : null;

			const userMessageId = uuidv4();
			const responseMessageId = uuidv4();

			const userMessage = {
				id: userMessageId,
				parentId: parentMessage ? parentMessage.id : null,
				childrenIds: [responseMessageId],
				role: 'user',
				content: userPrompt ? userPrompt : `[PROMPT] ${userMessageId}`,
				timestamp: Math.floor(Date.now() / 1000)
			};

			const responseMessage = {
				id: responseMessageId,
				parentId: userMessageId,
				childrenIds: [],
				role: 'assistant',
				content: `[RESPONSE] ${responseMessageId}`,
				done: true,

				model: modelId,
				modelName: model.name ?? model.id,
				modelIdx: 0,
				timestamp: Math.floor(Date.now() / 1000)
			};

			if (parentMessage) {
				parentMessage.childrenIds.push(userMessageId);
				history.messages[parentMessage.id] = parentMessage;
			}
			history.messages[userMessageId] = userMessage;
			history.messages[responseMessageId] = responseMessage;

			history.currentId = responseMessageId;

			await tick();

			if (autoScroll) {
				scrollToBottom();
			}

			if (messages.length === 0) {
				await initChatHandler(history);
			} else {
				await saveChatHandler($chatId, history);
			}
		}
	};

	const addMessages = async ({ modelId, parentId, messages }) => {
		const model = $models.filter((m) => m.id === modelId).at(0);

		let parentMessage = history.messages[parentId];
		let currentParentId = parentMessage ? parentMessage.id : null;
		for (const message of messages) {
			let messageId = uuidv4();

			if (message.role === 'user') {
				const userMessage = {
					id: messageId,
					parentId: currentParentId,
					childrenIds: [],
					timestamp: Math.floor(Date.now() / 1000),
					...message
				};

				if (parentMessage) {
					parentMessage.childrenIds.push(messageId);
					history.messages[parentMessage.id] = parentMessage;
				}

				history.messages[messageId] = userMessage;
				parentMessage = userMessage;
				currentParentId = messageId;
			} else {
				const responseMessage = {
					id: messageId,
					parentId: currentParentId,
					childrenIds: [],
					done: true,
					model: model.id,
					modelName: model.name ?? model.id,
					modelIdx: 0,
					timestamp: Math.floor(Date.now() / 1000),
					...message
				};

				if (parentMessage) {
					parentMessage.childrenIds.push(messageId);
					history.messages[parentMessage.id] = parentMessage;
				}

				history.messages[messageId] = responseMessage;
				parentMessage = responseMessage;
				currentParentId = messageId;
			}
		}

		history.currentId = currentParentId;
		await tick();

		if (autoScroll) {
			scrollToBottom();
		}

		if (messages.length === 0) {
			await initChatHandler(history);
		} else {
			await saveChatHandler($chatId, history);
		}
	};

	const chatCompletionEventHandler = async (data, message, chatId) => {
		const { id, done, choices, content, sources, selected_model_id, error, usage } = data;

		if (error) {
			await handleOpenAIError(error, message);
		}

		if (sources) {
			message.sources = sources;
		}

		if (choices) {
			if (choices[0]?.message?.content) {
				// Non-stream response
				message.content += choices[0]?.message?.content;
			} else {
				// Stream response
				let value = choices[0]?.delta?.content ?? '';
				if (message.content == '' && value == '\n') {
					console.log('Empty response');
				} else {
					message.content += value;

					if (navigator.vibrate && ($settings?.hapticFeedback ?? false)) {
						navigator.vibrate(5);
					}

					// Emit chat event for TTS
					const messageContentParts = getMessageContentParts(
						message.content,
						$config?.audio?.tts?.split_on ?? 'punctuation'
					);
					messageContentParts.pop();

					// dispatch only last sentence and make sure it hasn't been dispatched before
					if (
						messageContentParts.length > 0 &&
						messageContentParts[messageContentParts.length - 1] !== message.lastSentence
					) {
						message.lastSentence = messageContentParts[messageContentParts.length - 1];
						eventTarget.dispatchEvent(
							new CustomEvent('chat', {
								detail: {
									id: message.id,
									content: messageContentParts[messageContentParts.length - 1]
								}
							})
						);
					}
				}
			}
		}

		if (content) {
			// REALTIME_CHAT_SAVE is disabled
			message.content = content;

			if (navigator.vibrate && ($settings?.hapticFeedback ?? false)) {
				navigator.vibrate(5);
			}

			// Emit chat event for TTS
			const messageContentParts = getMessageContentParts(
				message.content,
				$config?.audio?.tts?.split_on ?? 'punctuation'
			);
			messageContentParts.pop();

			// dispatch only last sentence and make sure it hasn't been dispatched before
			if (
				messageContentParts.length > 0 &&
				messageContentParts[messageContentParts.length - 1] !== message.lastSentence
			) {
				message.lastSentence = messageContentParts[messageContentParts.length - 1];
				eventTarget.dispatchEvent(
					new CustomEvent('chat', {
						detail: {
							id: message.id,
							content: messageContentParts[messageContentParts.length - 1]
						}
					})
				);
			}
		}

		if (selected_model_id) {
			message.selectedModelId = selected_model_id;
			message.arena = true;
		}

		if (usage) {
			message.usage = usage;
		}

		history.messages[message.id] = message;

		if (done) {
			message.done = true;

			if ($settings.responseAutoCopy) {
				copyToClipboard(message.content);
			}

			if ($settings.responseAutoPlayback && !$showCallOverlay) {
				await tick();
				document.getElementById(`speak-button-${message.id}`)?.click();
			}

			// Emit chat event for TTS
			let lastMessageContentPart =
				getMessageContentParts(message.content, $config?.audio?.tts?.split_on ?? 'punctuation')?.at(
					-1
				) ?? '';
			if (lastMessageContentPart) {
				eventTarget.dispatchEvent(
					new CustomEvent('chat', {
						detail: { id: message.id, content: lastMessageContentPart }
					})
				);
			}
			eventTarget.dispatchEvent(
				new CustomEvent('chat:finish', {
					detail: {
						id: message.id,
						content: message.content
					}
				})
			);

			history.messages[message.id] = message;
			await chatCompletedHandler(
				chatId,
				message.model,
				message.id,
				createMessagesList(history, message.id)
			);
		}

		console.log(data);
		if (autoScroll) {
			scrollToBottom();
		}
	};

	//////////////////////////
	// Chat functions
	//////////////////////////

	const submitPrompt = async (userPrompt, { _raw = false } = {}) => {
		console.log('submitPrompt', userPrompt, $chatId);

		const messages = createMessagesList(history, history.currentId);
		const _selectedModels = selectedModels.map((modelId) =>
			$models.map((m) => m.id).includes(modelId) ? modelId : ''
		);
		if (JSON.stringify(selectedModels) !== JSON.stringify(_selectedModels)) {
			selectedModels = _selectedModels;
		}

		if (userPrompt === '' && files.length === 0) {
			toast.error($i18n.t('Please enter a prompt'));
			return;
		}
		if (selectedModels.includes('')) {
			toast.error($i18n.t('Model not selected'));
			return;
		}

		if (messages.length != 0 && messages.at(-1).done != true) {
			// Response not done
			return;
		}
		if (messages.length != 0 && messages.at(-1).error && !messages.at(-1).content) {
			// Error in response
			toast.error($i18n.t(`Oops! There was an error in the previous response.`));
			return;
		}
		if (
			files.length > 0 &&
			files.filter((file) => file.type !== 'image' && file.status === 'uploading').length > 0
		) {
			toast.error(
				$i18n.t(`Oops! There are files still uploading. Please wait for the upload to complete.`)
			);
			return;
		}
		if (
			($config?.file?.max_count ?? null) !== null &&
			files.length + chatFiles.length > $config?.file?.max_count
		) {
			toast.error(
				$i18n.t(`You can only chat with a maximum of {{maxCount}} file(s) at a time.`, {
					maxCount: $config?.file?.max_count
				})
			);
			return;
		}

		prompt = '';

		// Reset chat input textarea
		if (!($settings?.richTextInput ?? true)) {
			const chatInputElement = document.getElementById('chat-input');

			if (chatInputElement) {
				await tick();
				chatInputElement.style.height = '';
			}
		}

		const _files = JSON.parse(JSON.stringify(files));
		chatFiles.push(..._files.filter((item) => ['doc', 'file', 'collection'].includes(item.type)));
		chatFiles = chatFiles.filter(
			// Remove duplicates
			(item, index, array) =>
				array.findIndex((i) => JSON.stringify(i) === JSON.stringify(item)) === index
		);

		files = [];
		prompt = '';

		// Create user message
		let userMessageId = uuidv4();
		let userMessage = {
			id: userMessageId,
			parentId: messages.length !== 0 ? messages.at(-1).id : null,
			childrenIds: [],
			role: 'user',
			content: userPrompt,
			files: _files.length > 0 ? _files : undefined,
			timestamp: Math.floor(Date.now() / 1000), // Unix epoch
			models: selectedModels
		};

		// Add message to history and Set currentId to messageId
		history.messages[userMessageId] = userMessage;
		history.currentId = userMessageId;

		// Append messageId to childrenIds of parent message
		if (messages.length !== 0) {
			history.messages[messages.at(-1).id].childrenIds.push(userMessageId);
		}

		// focus on chat input
		const chatInput = document.getElementById('chat-input');
		chatInput?.focus();

		saveSessionSelectedModels();

		await sendPrompt(history, userPrompt, userMessageId, { newChat: true });
	};

	const sendPrompt = async (
		_history,
		prompt: string,
		parentId: string,
		{ modelId = null, modelIdx = null, newChat = false } = {}
	) => {
		if (autoScroll) {
			scrollToBottom();
		}

		let _chatId = JSON.parse(JSON.stringify($chatId));
		_history = JSON.parse(JSON.stringify(_history));

		const responseMessageIds: Record<PropertyKey, string> = {};
		// If modelId is provided, use it, else use selected model
		let selectedModelIds = modelId
			? [modelId]
			: atSelectedModel !== undefined
				? [atSelectedModel.id]
				: selectedModels;

		// Create response messages for each selected model
		for (const [_modelIdx, modelId] of selectedModelIds.entries()) {
			const model = $models.filter((m) => m.id === modelId).at(0);

			if (model) {
				let responseMessageId = uuidv4();
				let responseMessage = {
					parentId: parentId,
					id: responseMessageId,
					childrenIds: [],
					role: 'assistant',
					content: '',
					model: model.id,
					modelName: model.name ?? model.id,
					modelIdx: modelIdx ? modelIdx : _modelIdx,
					userContext: null,
					timestamp: Math.floor(Date.now() / 1000) // Unix epoch
				};

				// Add message to history and Set currentId to messageId
				history.messages[responseMessageId] = responseMessage;
				history.currentId = responseMessageId;

				// Append messageId to childrenIds of parent message
				if (parentId !== null && history.messages[parentId]) {
					// Add null check before accessing childrenIds
					history.messages[parentId].childrenIds = [
						...history.messages[parentId].childrenIds,
						responseMessageId
					];
				}

				responseMessageIds[`${modelId}-${modelIdx ? modelIdx : _modelIdx}`] = responseMessageId;
			}
		}
		history = history;

		// Create new chat if newChat is true and first user message
		if (newChat && _history.messages[_history.currentId].parentId === null) {
			_chatId = await initChatHandler(_history);
		}

		await tick();

		_history = JSON.parse(JSON.stringify(history));
		// Save chat after all messages have been created
		await saveChatHandler(_chatId, _history);

		await Promise.all(
			selectedModelIds.map(async (modelId, _modelIdx) => {
				console.log('modelId', modelId);
				const model = $models.filter((m) => m.id === modelId).at(0);

				if (model) {
					const messages = createMessagesList(_history, parentId);
					// If there are image files, check if model is vision capable
					const hasImages = messages.some((message) =>
						message.files?.some((file) => file.type === 'image')
					);

					if (hasImages && !(model.info?.meta?.capabilities?.vision ?? true)) {
						toast.error(
							$i18n.t('Model {{modelName}} is not vision capable', {
								modelName: model.name ?? model.id
							})
						);
					}

					let responseMessageId =
						responseMessageIds[`${modelId}-${modelIdx ? modelIdx : _modelIdx}`];
					let responseMessage = _history.messages[responseMessageId];

					let userContext = null;
					if ($settings?.memory ?? false) {
						if (userContext === null) {
							const res = await queryMemory(localStorage.token, prompt).catch((error) => {
								toast.error(`${error}`);
								return null;
							});
							if (res) {
								if (res.documents[0].length > 0) {
									userContext = res.documents[0].reduce((acc, doc, index) => {
										const createdAtTimestamp = res.metadatas[0][index].created_at;
										const createdAtDate = new Date(createdAtTimestamp * 1000)
											.toISOString()
											.split('T')[0];
										return `${acc}${index + 1}. [${createdAtDate}]. ${doc}\n`;
									}, '');
								}

								console.log(userContext);
							}
						}
					}
					responseMessage.userContext = userContext;

					const chatEventEmitter = await getChatEventEmitter(model.id, _chatId);

					scrollToBottom();
					await sendPromptSocket(_history, model, responseMessageId, _chatId);

					if (chatEventEmitter) clearInterval(chatEventEmitter);
				} else {
					toast.error($i18n.t(`Model {{modelId}} not found`, { modelId }));
				}
			})
		);

		currentChatPage.set(1);
		chats.set(await getChatList(localStorage.token, $currentChatPage));
	};

	const sendPromptSocket = async (_history, model, responseMessageId, _chatId) => {
		const chatMessages = createMessagesList(history, history.currentId);
		const responseMessage = _history.messages[responseMessageId];
		const userMessage = _history.messages[responseMessage.parentId];

		const chatMessageFiles = chatMessages
			.filter((message) => message.files)
			.flatMap((message) => message.files);

		// Filter chatFiles to only include files that are in the chatMessageFiles
		chatFiles = chatFiles.filter((item) => {
			const fileExists = chatMessageFiles.some((messageFile) => messageFile.id === item.id);
			return fileExists;
		});

		let files = JSON.parse(JSON.stringify(chatFiles));
		files.push(
			...(userMessage?.files ?? []).filter((item) =>
				['doc', 'file', 'collection'].includes(item.type)
			),
			...(responseMessage?.files ?? []).filter((item) => ['web_search_results'].includes(item.type))
		);
		// Remove duplicates
		files = files.filter(
			(item, index, array) =>
				array.findIndex((i) => JSON.stringify(i) === JSON.stringify(item)) === index
		);

		scrollToBottom();
		eventTarget.dispatchEvent(
			new CustomEvent('chat:start', {
				detail: {
					id: responseMessageId
				}
			})
		);
		await tick();

		const stream =
			model?.info?.params?.stream_response ??
			$settings?.params?.stream_response ??
			params?.stream_response ??
			true;

		let messages = [
			params?.system || $settings.system || (responseMessage?.userContext ?? null)
				? {
						role: 'system',
						content: `${promptTemplate(
							params?.system ?? $settings?.system ?? '',
							$user?.name,
							$settings?.userLocation
								? await getAndUpdateUserLocation(localStorage.token).catch((err) => {
										console.error(err);
										return undefined;
									})
								: undefined
						)}${
							(responseMessage?.userContext ?? null)
								? `\n\nUser Context:\n${responseMessage?.userContext ?? ''}`
								: ''
						}`
					}
				: undefined,
			...createMessagesList(_history, responseMessageId).map((message) => ({
				...message,
				content: processDetails(message.content)
			}))
		].filter((message) => message);

		messages = messages
			.map((message, idx, arr) => ({
				role: message.role,
				...((message.files?.filter((file) => file.type === 'image').length > 0 ?? false) &&
				message.role === 'user'
					? {
							content: [
								{
									type: 'text',
									text: message?.merged?.content ?? message.content
								},
								...message.files
									.filter((file) => file.type === 'image')
									.map((file) => ({
										type: 'image_url',
										image_url: {
											url: file.url
										}
									}))
							]
						}
					: {
							content: message?.merged?.content ?? message.content
						})
			}))
			.filter((message) => message?.role === 'user' || message?.content?.trim());

		const res = await generateOpenAIChatCompletion(
			localStorage.token,
			{
				stream: stream,
				model: model.id,
				messages: messages,
				params: {
					...$settings?.params,
					...params,

					format: $settings.requestFormat ?? undefined,
					keep_alive: $settings.keepAlive ?? undefined,
					stop:
						(params?.stop ?? $settings?.params?.stop ?? undefined)
							? (params?.stop.split(',').map((token) => token.trim()) ?? $settings.params.stop).map(
									(str) => decodeURIComponent(JSON.parse('"' + str.replace(/\"/g, '\\"') + '"'))
								)
							: undefined
				},

				files: (files?.length ?? 0) > 0 ? files : undefined,

				filter_ids: selectedFilterIds.length > 0 ? selectedFilterIds : undefined,
				tool_ids: selectedToolIds.length > 0 ? selectedToolIds : undefined,
				tool_servers: $toolServers,

				features: {
					image_generation:
						$config?.features?.enable_image_generation &&
						($user?.role === 'admin' || $user?.permissions?.features?.image_generation)
							? imageGenerationEnabled
							: false,
					code_interpreter:
						$config?.features?.enable_code_interpreter &&
						($user?.role === 'admin' || $user?.permissions?.features?.code_interpreter)
							? codeInterpreterEnabled
							: false,
					web_search:
						$config?.features?.enable_web_search &&
						($user?.role === 'admin' || $user?.permissions?.features?.web_search)
							? webSearchEnabled || ($settings?.webSearch ?? false) === 'always'
							: false
				},
				variables: {
					...getPromptVariables(
						$user?.name,
						$settings?.userLocation
							? await getAndUpdateUserLocation(localStorage.token).catch((err) => {
									console.error(err);
									return undefined;
								})
							: undefined
					)
				},
				model_item: $models.find((m) => m.id === model.id),

				session_id: $socket?.id,
				chat_id: $chatId,
				id: responseMessageId,

				...(!$temporaryChatEnabled &&
				(messages.length == 1 ||
					(messages.length == 2 &&
						messages.at(0)?.role === 'system' &&
						messages.at(1)?.role === 'user')) &&
				(selectedModels[0] === model.id || atSelectedModel !== undefined)
					? {
							background_tasks: {
								title_generation: $settings?.title?.auto ?? true,
								tags_generation: $settings?.autoTags ?? true
							}
						}
					: {}),

				...(stream && (model.info?.meta?.capabilities?.usage ?? false)
					? {
							stream_options: {
								include_usage: true
							}
						}
					: {})
			},
			`${WEBUI_BASE_URL}/api`
		).catch(async (error) => {
			toast.error(`${error}`);

			responseMessage.error = {
				content: error
			};
			responseMessage.done = true;

			history.messages[responseMessageId] = responseMessage;
			history.currentId = responseMessageId;
			return null;
		});

		if (res) {
			if (res.error) {
				await handleOpenAIError(res.error, responseMessage);
			} else {
				if (taskIds) {
					taskIds.push(res.task_id);
				} else {
					taskIds = [res.task_id];
				}
			}
		}

		await tick();
		scrollToBottom();
	};

	const handleOpenAIError = async (error, responseMessage) => {
		let errorMessage = '';
		let innerError;

		if (error) {
			innerError = error;
		}

		console.error(innerError);
		if ('detail' in innerError) {
			// FastAPI error
			toast.error(innerError.detail);
			errorMessage = innerError.detail;
		} else if ('error' in innerError) {
			// OpenAI error
			if ('message' in innerError.error) {
				toast.error(innerError.error.message);
				errorMessage = innerError.error.message;
			} else {
				toast.error(innerError.error);
				errorMessage = innerError.error;
			}
		} else if ('message' in innerError) {
			// OpenAI error
			toast.error(innerError.message);
			errorMessage = innerError.message;
		}

		responseMessage.error = {
			content: $i18n.t(`Uh-oh! There was an issue with the response.`) + '\n' + errorMessage
		};
		responseMessage.done = true;

		if (responseMessage.statusHistory) {
			responseMessage.statusHistory = responseMessage.statusHistory.filter(
				(status) => status.action !== 'knowledge_search'
			);
		}

		history.messages[responseMessage.id] = responseMessage;
	};

	const stopResponse = async () => {
		if (taskIds) {
			for (const taskId of taskIds) {
				const res = await stopTask(localStorage.token, taskId).catch((error) => {
					toast.error(`${error}`);
					return null;
				});
			}

			taskIds = null;

			const responseMessage = history.messages[history.currentId];
			// Set all response messages to done
			for (const messageId of history.messages[responseMessage.parentId].childrenIds) {
				history.messages[messageId].done = true;
			}

			history.messages[history.currentId] = responseMessage;

			if (autoScroll) {
				scrollToBottom();
			}
		}
	};

	const submitMessage = async (parentId, prompt) => {
		let userPrompt = prompt;
		let userMessageId = uuidv4();

		let userMessage = {
			id: userMessageId,
			parentId: parentId,
			childrenIds: [],
			role: 'user',
			content: userPrompt,
			models: selectedModels
		};

		if (parentId !== null) {
			history.messages[parentId].childrenIds = [
				...history.messages[parentId].childrenIds,
				userMessageId
			];
		}

		history.messages[userMessageId] = userMessage;
		history.currentId = userMessageId;

		await tick();

		if (autoScroll) {
			scrollToBottom();
		}

		await sendPrompt(history, userPrompt, userMessageId);
	};

	const regenerateResponse = async (message) => {
		console.log('regenerateResponse');

		if (history.currentId) {
			let userMessage = history.messages[message.parentId];
			let userPrompt = userMessage.content;

			if (autoScroll) {
				scrollToBottom();
			}

			if ((userMessage?.models ?? [...selectedModels]).length == 1) {
				// If user message has only one model selected, sendPrompt automatically selects it for regeneration
				await sendPrompt(history, userPrompt, userMessage.id);
			} else {
				// If there are multiple models selected, use the model of the response message for regeneration
				// e.g. many model chat
				await sendPrompt(history, userPrompt, userMessage.id, {
					modelId: message.model,
					modelIdx: message.modelIdx
				});
			}
		}
	};

	const continueResponse = async () => {
		console.log('continueResponse');
		const _chatId = JSON.parse(JSON.stringify($chatId));

		if (history.currentId && history.messages[history.currentId].done == true) {
			const responseMessage = history.messages[history.currentId];
			responseMessage.done = false;
			await tick();

			const model = $models
				.filter((m) => m.id === (responseMessage?.selectedModelId ?? responseMessage.model))
				.at(0);

			if (model) {
				await sendPromptSocket(history, model, responseMessage.id, _chatId);
			}
		}
	};

	const mergeResponses = async (messageId, responses, _chatId) => {
		console.log('mergeResponses', messageId, responses);
		const message = history.messages[messageId];
		const mergedResponse = {
			status: true,
			content: ''
		};
		message.merged = mergedResponse;
		history.messages[messageId] = message;

		try {
			const [res, controller] = await generateMoACompletion(
				localStorage.token,
				message.model,
				history.messages[message.parentId].content,
				responses
			);

			if (res && res.ok && res.body) {
				const textStream = await createOpenAITextStream(res.body, $settings.splitLargeChunks);
				for await (const update of textStream) {
					const { value, done, sources, error, usage } = update;
					if (error || done) {
						break;
					}

					if (mergedResponse.content == '' && value == '\n') {
						continue;
					} else {
						mergedResponse.content += value;
						history.messages[messageId] = message;
					}

					if (autoScroll) {
						scrollToBottom();
					}
				}

				await saveChatHandler(_chatId, history);
			} else {
				console.error(res);
			}
		} catch (e) {
			console.error(e);
		}
	};

	const initChatHandler = async (history) => {
		let _chatId = $chatId;

		if (!$temporaryChatEnabled) {
			chat = await createNewChat(localStorage.token, {
				id: _chatId,
				title: $i18n.t('New Chat'),
				models: selectedModels,
				system: $settings.system ?? undefined,
				params: params,
				history: history,
				messages: createMessagesList(history, history.currentId),
				tags: [],
				timestamp: Date.now()
			});

			_chatId = chat.id;
			await chatId.set(_chatId);

			await chats.set(await getChatList(localStorage.token, $currentChatPage));
			currentChatPage.set(1);

			window.history.replaceState(history.state, '', `/c/${_chatId}`);
		} else {
			_chatId = 'local';
			await chatId.set('local');
		}
		await tick();

		return _chatId;
	};

	const saveChatHandler = async (_chatId, history) => {
		if ($chatId == _chatId) {
			if (!$temporaryChatEnabled) {
				chat = await updateChatById(localStorage.token, _chatId, {
					models: selectedModels,
					history: history,
					messages: createMessagesList(history, history.currentId),
					params: params,
					files: chatFiles
				});
				currentChatPage.set(1);
				await chats.set(await getChatList(localStorage.token, $currentChatPage));
			}
		}
	};
</script>

<svelte:head>
	<title>
		{$chatTitle
			? `${$chatTitle.length > 30 ? `${$chatTitle.slice(0, 30)}...` : $chatTitle} • ${$WEBUI_NAME}`
			: `${$WEBUI_NAME}`}
	</title>
</svelte:head>

<audio id="audioElement" src="" style="display: none;" />

<EventConfirmDialog
	bind:show={showEventConfirmation}
	title={eventConfirmationTitle}
	message={eventConfirmationMessage}
	input={eventConfirmationInput}
	inputPlaceholder={eventConfirmationInputPlaceholder}
	inputValue={eventConfirmationInputValue}
	on:confirm={(e) => {
		if (e.detail) {
			eventCallback(e.detail);
		} else {
			eventCallback(true);
		}
	}}
	on:cancel={() => {
		eventCallback(false);
	}}
/>
<div
	class="h-screen max-h-[100dvh] transition-all duration-300 ease-in-out {$showSidebar
		? 'md:max-w-[calc(100%-180px)]'
		: 'md:max-w-[calc(100%-100px)]'} w-full max-w-full flex flex-col "
	id="chat-container"
>
<div class="flex h-6"></div>
<div class="bg-white  w-full max-w-full flex flex-col rounded-tl-[20px] rounded-bl-[20px] h-screen py-2">
	{#if !loading}
		{#if $settings?.backgroundImageUrl ?? null}
			<div
				class="absolute {$showSidebar
					? 'md:max-w-[calc(100%-180px)] md:translate-x-[180px]'
					: 'md:max-w-[calc(100%-100px)] md:translate-x-[100px]'} top-0 left-0 w-full h-full bg-cover bg-center bg-no-repeat"
				style="background-image: url({$settings.backgroundImageUrl})  "
			/>

			<div
				class="absolute top-0 left-0 w-full h-full bg-linear-to-t from-white to-white/85 dark:from-gray-900 dark:to-gray-900/90 z-0"
			/>
		{/if}

		<PaneGroup direction="horizontal" class="w-full h-full">
			<Pane defaultSize={50} class="h-full flex relative max-w-full flex-col">
				<Navbar
					bind:this={navbarElement}
					chat={{
						id: $chatId,
						chat: {
							title: $chatTitle,
							models: selectedModels,
							system: $settings.system ?? undefined,
							params: params,
							history: history,
							timestamp: Date.now()
						}
					}}
					{history}
					title={$chatTitle}
					bind:selectedModels
					shareEnabled={!!history.currentId}
					showModelSelector={createMessagesList(history, history.currentId).length > 0 || (chatIdProp && $settings?.landingPageMode !== 'chat')}
					{initNewChat}
				/>

				<div class="flex flex-col flex-auto z-10 w-full items-center @container">
					{#if createMessagesList(history, history.currentId).length > 0}
						<div
							class=" pb-2.5 flex flex-col justify-between w-full flex-auto overflow-auto h-0 max-w-full z-10 scrollbar-hidden"
							id="messages-container"
							bind:this={messagesContainerElement}
							on:scroll={(e) => {
								autoScroll =
									messagesContainerElement.scrollHeight - messagesContainerElement.scrollTop <=
									messagesContainerElement.clientHeight + 5;
							}}
						>
							<div class=" h-full w-full flex flex-col">
								<Messages
									chatId={$chatId}
									bind:history
									bind:autoScroll
									bind:prompt
									{selectedModels}
									{atSelectedModel}
									{sendPrompt}
									{showMessage}
									{submitMessage}
									{continueResponse}
									{regenerateResponse}
									{mergeResponses}
									{chatActionHandler}
									{addMessages}
									bottomPadding={files.length > 0}
								/>
							</div>
						</div>

						<div class="pb-[1rem] flex justify-center px-6">
							<div class="w-full">
								<MessageInput
									{history}
									{taskIds}
									{selectedModels}
									bind:files
									bind:prompt
									bind:autoScroll
									bind:selectedToolIds
									bind:selectedFilterIds
									bind:imageGenerationEnabled
									bind:codeInterpreterEnabled
									bind:webSearchEnabled
									bind:atSelectedModel
									toolServers={$toolServers}
									transparentBackground={$settings?.backgroundImageUrl ?? false}
									{stopResponse}
									{createMessagePair}
									onChange={(input) => {
										if (input.prompt !== null) {
											localStorage.setItem(
												`chat-input${$chatId ? `-${$chatId}` : ''}`,
												JSON.stringify(input)
											);
										} else {
											localStorage.removeItem(`chat-input${$chatId ? `-${$chatId}` : ''}`);
										}
									}}
									on:upload={async (e) => {
										const { type, data } = e.detail;

										if (type === 'web') {
											await uploadWeb(data);
										} else if (type === 'youtube') {
											await uploadYoutubeTranscription(data);
										} else if (type === 'google-drive') {
											await uploadGoogleDriveFile(data);
										}
									}}
									on:submit={async (e) => {
										if (e.detail || files.length > 0) {
											await tick();
											submitPrompt(
												($settings?.richTextInput ?? true)
													? e.detail.replaceAll('\n\n', '\n')
													: e.detail
											);
										}
									}}
								/>

								<div
									class="absolute bottom-1 text-xs text-gray-500 text-center line-clamp-1 right-0 left-0"
								>
									<!-- {$i18n.t('LLMs can make mistakes. Verify important information.')} -->
								</div>
							</div>
						</div>
					{:else if chatIdProp && $settings?.landingPageMode !== 'chat'}
						<!-- 新聊天会话时显示简洁的消息输入框，位置与有消息时一致 -->
						<div class="w-full h-full flex flex-col">
							<!-- 空的消息区域，占据剩余空间 -->
							<div class="flex-auto"></div>
							
							<!-- 消息输入框，位置与有消息时保持一致 -->
							<div class="pb-[1rem] flex justify-center px-6">
								<div class="w-full">
									<MessageInput
										{history}
										{taskIds}
										{selectedModels}
										bind:files
										bind:prompt
										bind:autoScroll
										bind:selectedToolIds
										bind:selectedFilterIds
										bind:imageGenerationEnabled
										bind:codeInterpreterEnabled
										bind:webSearchEnabled
										bind:atSelectedModel
										toolServers={$toolServers}
										transparentBackground={$settings?.backgroundImageUrl ?? false}
										{stopResponse}
										{createMessagePair}
										placeholder={$i18n.t('How can I help you today?')}
										onChange={(input) => {
											if (input.prompt !== null) {
												localStorage.setItem(
													`chat-input${$chatId ? `-${$chatId}` : ''}`,
													JSON.stringify(input)
												);
											} else {
												localStorage.removeItem(`chat-input${$chatId ? `-${$chatId}` : ''}`);
											}
										}}
										on:upload={async (e) => {
											const { type, data } = e.detail;

											if (type === 'web') {
												await uploadWeb(data);
											} else if (type === 'youtube') {
												await uploadYoutubeTranscription(data);
											}
										}}
										on:submit={async (e) => {
											if (e.detail || files.length > 0) {
												await tick();
												submitPrompt(
													($settings?.richTextInput ?? true)
														? e.detail.replaceAll('\n\n', '\n')
														: e.detail
												);
											}
										}}
									/>

									<div
										class="absolute bottom-1 text-xs text-gray-500 text-center line-clamp-1 right-0 left-0"
									>
										<!-- {$i18n.t('LLMs can make mistakes. Verify important information.')} -->
									</div>
								</div>
							</div>
						</div>
					{:else}
						<div class="overflow-auto w-full h-full flex flex-col items-center ai-assistant">
							<!-- AI助手导航页面 -->
							<div class="ai-assistant-container">
								<div class="ai-assistant-content">
									<!-- 头部 -->
									<div class="ai-header">
										<div class="box_2 flex-row justify-between">
											<img
												class="image_1"
												referrerpolicy="no-referrer"
												src="/assets/images/SketchPn_13.png"
											/>
											<span class="text_1">万语千言，心领神悟</span>
										</div>
										<div class="text-wrapper_1 flex-row">
											<span class="text_2">我是agent，你的实用AI助手</span>
										</div>
									</div>

									<!-- 主内容 -->
									<div class="ai-main-content">
										<!-- 精选工具卡片 -->
										<div class="ai-card ai-agents-card">
											<div class="group_4 flex-col">
												<div class="text-wrapper_2 flex-row justify-between">
													<span class="text_3">精选工具</span>
													<span class="text_4">发现更多</span>
												</div>
												<div class="group_5 flex-row justify-between">
																						<div class="group_6 flex-row" 
										on:mouseenter={(e) => {
											const imgElement = e.currentTarget.querySelector('.image_2');
											if (imgElement && imgElement instanceof HTMLImageElement) {
												replayGif(imgElement);
											}
										}}
										on:click={async (e) => {
											const imgElement = e.currentTarget.querySelector('.image_2');
											if (imgElement && imgElement instanceof HTMLImageElement) {
												replayGif(imgElement);
											}
											// 新建会话并选择"金助"模型
											await createNewChatWithModel('金助');
										}}>
										<div class="image-text_1 flex-col justify-between">
											<div class="box_4 flex-col"></div>
											<div class="text-group_1 flex-col justify-between">
												<span class="text_5">集团制度助手</span>
												<span class="paragraph_1"
													>智能解答集团制度疑问<br />秒查最新条款，事务处理快人一步。</span
												>
											</div>
										</div>
										<img
											class="image_2"
											referrerpolicy="no-referrer"
											src="/assets/images/SketchPn_16.gif"
											alt="SketchPn_16"
											loading="eager"
											decoding="async"
										/>
									</div>
													<div class="group_7 flex-row"
														on:mouseenter={(e) => {
															const imgElement = e.currentTarget.querySelector('.image_3');
															if (imgElement) {
																replayGif(imgElement);
															}
														}}
														on:click={(e) => {
															const imgElement = e.currentTarget.querySelector('.image_3');
															if (imgElement) {
																replayGif(imgElement);
															}
															window.open(`http://192.168.3.180:3000/validate?token=${localStorage.token}`);
														}}>
														<div class="image-text_2 flex-col justify-between">
															<div class="block_1 flex-col"></div>
															<div class="text-group_2 flex-col justify-between">
																<span class="text_6">董事会议题比对助手</span>
																<span class="text_7">一键核验议题变更，决策更高效</span>
															</div>
														</div>
														<img
															class="image_3"
															referrerpolicy="no-referrer"
															src="/assets/images/SketchPn_14.gif"
															alt="SketchPn_14"
															loading="eager"
															decoding="async"
														/>
													</div>
												</div>
											</div>
										</div>
										<!-- 效率工具卡片 -->
										<div class="ai-card ai-tools-card">
											<span class="text_8">效率工具</span>
											<div class="box_5 flex-row">
												<div class="text-group_3 flex-col justify-between">
													<span class="text_9">图文识别助手</span>
													<span class="text_10">秒级识别多语言/表格/手写体，解放人力</span>
												</div>
											</div>
											<div class="box_6 flex-row">
												<div class="image-text_3 flex-row justify-between">
													<div class="group_9 flex-col">
														<div class="section_1 flex-col"></div>
													</div>
													<div class="text-group_4 flex-col justify-between">
														<span class="text_11">睿宝儿童生长发育专家</span>
														<span class="text_12">精准预警偏离风险，科学育儿不焦虑</span>
													</div>
												</div>
											</div>
											<div class="box_7 flex-row">
												<div class="image-text_4 flex-row justify-between">
													<div class="box_8 flex-col"></div>
													<div class="text-group_5 flex-col justify-between">
														<span class="text_13">家庭财富配置助手</span>
														<span class="text_14">定制家庭资产方案，平衡风险与收益</span>
													</div>
												</div>
											</div>
										</div>
										<!-- PPT卡片 -->
										<div
											class="ai-card ai-carousel-card"
											on:mouseenter={pauseCarousel}
											on:mouseleave={startCarousel}
										>
											<div class="ai-carousel-container">
												<!-- 轮播内容 -->
												<div
													class="ai-carousel-slides"
													style="transform: translateX(-{currentSlide * 100}%)"
												>
													<!-- 第一个轮播：智能PPT生成工具 -->
													<div class="ai-carousel-slide ai-slide-unified">
														<div class="ppt-tool-container">
															<img
																class="ppt-merged-gif"
																referrerpolicy="no-referrer"
																src="/assets/images/merged.gif"
																alt="智能PPT生成工具"
																loading="eager"
																decoding="async"
															/>
															<div class="ppt-tool-title">
																<span class="text_21">智能PPT生成工具</span>
															</div>
														</div>
													</div>

													<!-- 第二个广告：PPT创作 -->
													<div class="ai-carousel-slide ai-slide-unified">
														<div class="ai-carousel-content">
															<h3 class="ai-carousel-title">PPT创作</h3>
															<p class="ai-carousel-desc">一键生成专业演示文稿，自动排版设计</p>
															<div class="ai-carousel-feature">
																<span class="ai-feature-tag">AI智能排版</span>
																<span class="ai-feature-tag">海量模板</span>
															</div>
															<button class="ai-carousel-button" on:click={showComingSoon}
																>立即体验 →</button
															>
														</div>
														<div class="ai-carousel-icon">📊</div>
													</div>

													<!-- 第三个广告：大图识别 -->
													<div class="ai-carousel-slide ai-slide-unified">
														<div class="ai-carousel-content">
															<h3 class="ai-carousel-title">大图识别</h3>
															<p class="ai-carousel-desc">
																轻松识别超大文字密集的扫描图，精准提取文本
															</p>
															<div class="ai-carousel-feature">
																<span class="ai-feature-tag">高精度识别</span>
																<span class="ai-feature-tag">大图支持</span>
															</div>
															<button class="ai-carousel-button" on:click={showComingSoon}
																>开始识别 →</button
															>
														</div>
														<div class="ai-carousel-icon">🔍</div>
													</div>

													<!-- 第四个广告：文档转换 -->
													<div class="ai-carousel-slide ai-slide-unified">
														<div class="ai-carousel-content">
															<h3 class="ai-carousel-title">文档转换</h3>
															<p class="ai-carousel-desc">OCR识别、格式转换，文档处理更高效</p>
															<div class="ai-carousel-feature">
																<span class="ai-feature-tag">批量处理</span>
																<span class="ai-feature-tag">格式互转</span>
															</div>
															<button class="ai-carousel-button" on:click={showComingSoon}
																>开始使用 →</button
															>
														</div>
														<div class="ai-carousel-icon">📄</div>
													</div>
												</div>

												<!-- 轮播指示器 -->
												<div class="ai-carousel-indicators">
													{#each Array(totalSlides) as _, index}
														<button
															class="ai-carousel-dot {currentSlide === index ? 'active' : ''}"
															on:click={() => {
																currentSlide = index;
																// 点击后重新启动轮播
																startCarousel();
															}}
														></button>
													{/each}
												</div>
											</div>
										</div>
									</div>
								</div>
							</div>
							<Placeholder
								{history}
								{selectedModels}
								bind:files
								bind:prompt
								bind:autoScroll
								bind:selectedToolIds
								bind:selectedFilterIds
								bind:imageGenerationEnabled
								bind:codeInterpreterEnabled
								bind:webSearchEnabled
								bind:atSelectedModel
								transparentBackground={$settings?.backgroundImageUrl ?? false}
								toolServers={$toolServers}
								{stopResponse}
								{createMessagePair}
								on:upload={async (e) => {
									const { type, data } = e.detail;

									if (type === 'web') {
										await uploadWeb(data);
									} else if (type === 'youtube') {
										await uploadYoutubeTranscription(data);
									}
								}}
								on:submit={async (e) => {
									if (e.detail || files.length > 0) {
										await tick();
										submitPrompt(
											($settings?.richTextInput ?? true)
												? e.detail.replaceAll('\n\n', '\n')
												: e.detail
										);
									}
								}}
							/>
						</div>
					{/if}
				</div>

				<div class="flex justify-center h-5 text-xs text-gray-500" style="
				position: fixed;
				bottom: 20px;
				left: 45%;
			">
					内容由AI模型生成，其准确性和完整性无法保证，仅供参考
				</div>
			</Pane>

			<ChatControls
				bind:this={controlPaneComponent}
				bind:history
				bind:chatFiles
				bind:params
				bind:files
				bind:pane={controlPane}
				chatId={$chatId}
				modelId={selectedModelIds?.at(0) ?? null}
				models={selectedModelIds.reduce((a, e, i, arr) => {
					const model = $models.find((m) => m.id === e);
					if (model) {
						return [...a, model];
					}
					return a;
				}, [])}
				{submitPrompt}
				{stopResponse}
				{showMessage}
				{eventTarget}
			/>
		</PaneGroup>
	{:else if loading}
		<div class=" flex items-center justify-center h-full w-full">
			<div class="m-auto">
				<Spinner />
			</div>
		</div>
	{/if}
</div>

<!-- 隐藏的新会话按钮，供侧边栏调用 -->
<button 
	id="new-chat-button" 
	style="display: none;" 
	on:click={async () => {
		await initNewChat();
	}}
>
	New Chat
</button>

<div class="flex h-6"></div>
</div>
<style>
	/* AI助手导航页面样式 */
	.ai-assistant-container {
		width: 100%;
		height: auto;
		background-color: transparent;
		overflow: visible;
	}

	.ai-assistant-content {
		max-width: 1368px;
		margin: 0 auto;
		padding-top: 0; /* 顶部间距已由容器提供 */
	}

	/* 头部标题区域 */
	.ai-header {
		display: flex;
		flex-direction: column;
		margin-bottom: 32px;
		padding: 20px 0;
	}

	.box_2 {
		width: 514px;
		height: 71px;
		margin: 0;
		align-items: center;
	}

	.image_1 {
		width: 70px;
		height: 69px;
		margin-top: 1px;
	}

	.text_1 {
		width: 432px;
		height: 70px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 48px;
		font-family: SourceHanSansSC-Heavy;
		font-weight: 900;
		text-align: left;
		white-space: nowrap;
		line-height: 70px;
		margin-left: 16px;
	}

	.text-wrapper_1 {
		width: 231px;
		height: 27px;
		margin: 16px 0 0 0;
	}

	.text_2 {
		width: 231px;
		height: 27px;
		overflow-wrap: break-word;
		color: rgba(145, 145, 145, 1);
		font-size: 18px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 27px;
	}

	.ai-logo {
		width: 48px;
		height: 48px;
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		border-radius: 12px;
		display: flex;
		align-items: center;
		justify-content: center;
		margin-right: 12px;
		box-shadow: 0 2px 8px rgba(102, 126, 234, 0.2);
	}

	.ai-logo-icon {
		width: 28px;
		height: 28px;
		background: white;
		border-radius: 50%;
		position: relative;
	}

	.ai-header-text h1 {
		font-size: 20px;
		font-weight: 600;
		margin-bottom: 2px;
		color: #333;
	}

	.ai-header-text p {
		color: #666;
		font-size: 13px;
	}

	/* 主内容区域 */
	.ai-main-content {
		display: grid;
		grid-template-columns: 590px 369px 369px;
		gap: 20px;
		width: 1368px;
		height: 302px;
	}

	/* 卡片基础样式 */
	.ai-card {
		background: rgba(255, 255, 255, 0.7);
		backdrop-filter: blur(10px);
		border-radius: 12px;
		padding: 16px;
		box-shadow: 0 1px 4px rgba(0, 0, 0, 0.03);
	}

	.ai-card-title {
		font-size: 14px;
		font-weight: 600;
		margin-bottom: 12px;
		color: #1a1a1a;
	}

	/* 效率工具卡片 */
	.ai-tools-card {
		background: url(/assets/images/SketchPn_8.png)
			100% no-repeat;
		background-size: 100% 100%;
		width: 369px;
		height: 302px;
		padding: 0;
	}

	.ai-tools-grid {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 14px;
	}

	.ai-tool-item {
		display: flex;
		flex-direction: column;
		align-items: center;
		padding: 16px 12px;
		background: linear-gradient(
			135deg,
			rgba(255, 255, 255, 0.95) 0%,
			rgba(250, 250, 255, 0.9) 100%
		);
		border-radius: 10px;
		cursor: pointer;
		transition: all 0.3s ease;
		min-height: 90px;
		justify-content: center;
		border: 1px solid rgba(0, 0, 0, 0.03);
	}

	.ai-tool-item:nth-child(1) {
		background: linear-gradient(
			135deg,
			rgba(255, 248, 220, 0.95) 0%,
			rgba(255, 235, 180, 0.9) 100%
		);
	}

	.ai-tool-item:nth-child(2) {
		background: linear-gradient(
			135deg,
			rgba(245, 255, 245, 0.95) 0%,
			rgba(230, 255, 230, 0.9) 100%
		);
	}

	.ai-tool-item:nth-child(3) {
		background: linear-gradient(
			135deg,
			rgba(245, 245, 255, 0.95) 0%,
			rgba(230, 230, 255, 0.9) 100%
		);
	}

	.ai-tool-item:nth-child(4) {
		background: linear-gradient(
			135deg,
			rgba(255, 240, 255, 0.95) 0%,
			rgba(245, 220, 255, 0.9) 100%
		);
	}

	.ai-tool-item:hover {
		transform: translateY(-3px);
		box-shadow: 0 6px 16px rgba(0, 0, 0, 0.12);
		border-color: rgba(0, 0, 0, 0.06);
	}

	.ai-tool-icon {
		width: 40px;
		height: 40px;
		margin-bottom: 8px;
		display: flex;
		align-items: center;
		justify-content: center;
		font-size: 24px;
		background: rgba(255, 255, 255, 0.5);
		border-radius: 50%;
		backdrop-filter: blur(10px);
	}

	.ai-tool-name {
		font-size: 13px;
		color: #333;
		text-align: center;
		line-height: 1.3;
		font-weight: 500;
	}

	/* 精选智能体卡片 */
	.ai-agents-card {
		background: url(/assets/images/SketchPn_10.png)
			100% no-repeat;
		background-size: 100% 100%;
		height: 301px;
		padding: 0;
	}

	/* 精选工具相关样式 */
	.flex-col {
		display: flex;
		flex-direction: column;
	}
	.flex-row {
		display: flex;
		flex-direction: row;
	}
	.justify-between {
		display: flex;
		justify-content: space-between;
	}

	.group_4 {
		position: relative;
		height: 301px;
		width: 100%;
	}

	.text-wrapper_2 {
		width: 557px;
		height: 29px;
		margin: 16px 0 0 16px;
	}

	.text_3 {
		width: 80px;
		height: 29px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 20px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 29px;
	}

	.text_4 {
		width: 64px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(235, 146, 54, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Regular;
		font-weight: normal;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
		margin-top: 4px;
		cursor: pointer;
	}

	.group_5 {
		width: 558px;
		height: 187px;
		margin: 47px 0 22px 16px;
		position: relative;
	}

	.group_6 {
		width: 271px;
		height: 187px;
		background: url(/assets/images/SketchPn_6.png)
			100% no-repeat;
		background-size: 100% 100%;
		position: relative;
	}

	.group_7 {
		width: 271px;
		height: 187px;
		background: url(/assets/images/SketchPn_6.png)
			100% no-repeat;
		background-size: 100% 100%;
		margin-left: 16px;
		position: relative;
	}

	.image-text_1 {
		width: 229px;
		height: 145px;
		margin: 13px 0 0 19px;
	}

	.box_4 {
		width: 114px;
		height: 64px;
		background: url(/assets/images/SketchPn_9.png) -39px -43px
			no-repeat;
		background-size: 192px 150px;
	}

	.text-group_1 {
		width: 224px;
		height: 81px;
		margin-left: 5px;
	}

	.text_5 {
		width: 96px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
	}

	.paragraph_1 {
		width: 224px;
		height: 48px;
		overflow-wrap: break-word;
		color: rgba(145, 145, 145, 1);
		font-size: 14px;
		font-family: SourceHanSansSC-Regular;
		font-weight: normal;
		text-align: left;
		line-height: 24px;
		margin-top: 9px;
	}

	.image-text_2 {
		width: 201px;
		height: 121px;
		margin: 13px 0 0 19px;
	}

	.block_1 {
		width: 114px;
		height: 64px;
		background: url(/assets/images/SketchPn_19.png) -81px -88px
			no-repeat;
		background-size: 276px 240px;
	}

	.text-group_2 {
		width: 196px;
		height: 57px;
		margin-left: 5px;
	}

	.text_6 {
		width: 144px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
	}

	.text_7 {
		width: 196px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(145, 145, 145, 1);
		font-size: 14px;
		font-family: SourceHanSansSC-Regular;
		font-weight: normal;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
		margin-top: 9px;
	}

	.image_2 {
		position: absolute;
		left: 13px;
		top: -26px;
		width: 103px;
		height: 88px;
		/* 确保GIF动画能正常播放 */
		image-rendering: auto;
		object-fit: contain;
		pointer-events: none;
		z-index: 10;
	}

	.image_3 {
		position: absolute;
		left: 13px;
		top: -26px;
		width: 98px;
		height: 98px;
		/* 确保GIF动画能正常播放 */
		image-rendering: auto;
		object-fit: contain;
		pointer-events: none;
		z-index: 10;
	}

	/* Group交互样式 */
	.group_6, .group_7 {
		cursor: pointer;
		transition: transform 0.2s ease, opacity 0.2s ease;
	}

	.group_6:hover, .group_7:hover {
		transform: scale(1.02);
		opacity: 0.95;
	}

	.group_6:active, .group_7:active {
		transform: scale(0.98);
	}

	/* 效率工具卡片样式 */
	.text_8 {
		width: auto;
		min-width: 80px;
		height: 29px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 20px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 29px;
		margin: 16px 0 0 19px;
		display: block;
	}

	.box_5 {
		border-radius: 16px;
		background-image: url(/assets/images/merge_image_1.png);
		width: 328px;
		height: 64px;
		margin: 25px 0 0 19px;
	}

	.text-group_3 {
		width: 232px;
		height: 50px;
		margin: 7px 0 0 64px;
	}

	.text_9 {
		width: 96px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
	}

	.text_10 {
		width: 232px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(145, 145, 145, 1);
		font-size: 13px;
		font-family: SourceHanSansSC-Regular;
		font-weight: normal;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
		margin-top: 2px;
	}

	.box_6 {
		background-color: rgba(255, 255, 255, 1);
		border-radius: 16px;
		width: 328px;
		height: 64px;
		margin: 8px 0 0 19px;
	}

	.image-text_3 {
		width: 256px;
		height: 50px;
		margin: 7px 0 0 16px;
	}

	.group_9 {
		border-radius: 50%;
		background-image: url(/assets/images/merge_image_2.png);
		height: 40px;
		border: 1px solid rgba(151, 151, 151, 1);
		margin-top: 5px;
		width: 40px;
	}

	.section_1 {
		border-radius: 8px;
		background-image: url(/assets/images/merge_image_3.png);
		width: 40px;
		height: 40px;
	}

	.text-group_4 {
		width: 208px;
		height: 50px;
	}

	.text_11 {
		width: 160px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
	}

	.text_12 {
		width: 208px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(145, 145, 145, 1);
		font-size: 13px;
		font-family: SourceHanSansSC-Regular;
		font-weight: normal;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
		margin-top: 2px;
	}

	.box_7 {
		background-color: rgba(255, 255, 255, 1);
		border-radius: 16px;
		width: 328px;
		height: 64px;
		margin: 8px 0 24px 19px;
	}

	.image-text_4 {
		width: 256px;
		height: 50px;
		margin: 7px 0 0 16px;
	}

	.box_8 {
		border-radius: 50%;
		background-image: url(/assets/images/merge_image_6.png);
		width: 40px;
		height: 40px;
		border: 1px solid rgba(151, 151, 151, 1);
		margin-top: 5px;
	}

	.text-group_5 {
		width: 208px;
		height: 50px;
	}

	.text_13 {
		width: 128px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
	}

	.text_14 {
		width: 208px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(145, 145, 145, 1);
		font-size: 13px;
		font-family: SourceHanSansSC-Regular;
		font-weight: normal;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
		margin-top: 2px;
	}

	.ai-agent-item {
		display: flex;
		align-items: center;
		padding: 10px;
		background: rgba(255, 255, 255, 0.8);
		border-radius: 10px;
		margin-bottom: 8px;
		cursor: pointer;
		transition: all 0.3s ease;
	}

	.ai-agent-item:last-child {
		margin-bottom: 0;
	}

	.ai-agent-item:hover {
		transform: translateX(4px);
		box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
	}

	.ai-agent-item.active {
		background: rgba(102, 126, 234, 0.1);
		border: 1px solid rgba(102, 126, 234, 0.3);
	}

	.ai-agent-avatar {
		width: 36px;
		height: 36px;
		border-radius: 50%;
		margin-right: 10px;
		display: flex;
		align-items: center;
		justify-content: center;
		font-size: 16px;
		color: white;
	}

	.ai-agent-avatar.ai-purple {
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
	}

	.ai-agent-avatar.ai-orange {
		background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
	}

	.ai-agent-avatar.ai-blue {
		background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%);
	}

	.ai-agent-avatar.ai-green {
		background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
	}

	.ai-agent-info h3 {
		font-size: 13px;
		font-weight: 500;
		margin-bottom: 1px;
		color: #333;
	}

	.ai-agent-info p {
		font-size: 11px;
		color: #666;
		line-height: 1.3;
	}

	/* PPT卡片 */
	.ai-carousel-card {
		background: transparent;
		color: white;
		position: relative;
		overflow: hidden;
		/* 移除padding，让内容完全填充 */
		padding: 0;
		/* 移除边框 */
		border: none;
	}

	/* 使用更高优先级确保覆盖基础ai-card样式 */
	.ai-card.ai-carousel-card {
		padding: 0 !important;
		border: none !important;
		background: transparent !important;
		box-shadow: none !important;
	}

	/* 轮播项统一背景色 */
	.ai-slide-unified {
		background: url(/assets/images/SketchPn_7.png)
			100% no-repeat;
		background-size: 100% 100%;
		position: relative;
		overflow: hidden;
	}

	@keyframes float {
		0%,
		100% {
			transform: translate(0, 0) rotate(0deg);
		}
		25% {
			transform: translate(10%, 10%) rotate(90deg);
		}
		50% {
			transform: translate(-10%, 20%) rotate(180deg);
		}
		75% {
			transform: translate(20%, -10%) rotate(270deg);
		}
	}

	.ai-carousel-container {
		position: relative;
		z-index: 1;
		height: 100%;
		overflow: hidden;
		/* 保持圆角，与ai-card一致 */
		border-radius: 12px;
		/* 移除阴影，避免重复 */
	}

	.ai-carousel-slides {
		display: flex;
		transition: transform 0.5s cubic-bezier(0.4, 0, 0.2, 1);
		height: 100%;
	}

	.ai-carousel-slide {
		flex: 0 0 100%;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		padding: 24px;
		height: 100%;
		min-height: 100%;
		box-sizing: border-box;
		position: relative;
	}

	.ai-carousel-content {
		text-align: center;
		flex: 1;
		display: flex;
		flex-direction: column;
		justify-content: center;
		position: relative;
		z-index: 2;
	}

	.ai-carousel-title {
		font-size: 18px;
		font-weight: 600;
		margin-bottom: 10px;
		color: #1a1a1a;
		text-shadow: 0 1px 2px rgba(0, 0, 0, 0.05);
	}

	.ai-carousel-desc {
		font-size: 14px;
		color: #4a4a4a;
		margin-bottom: 16px;
		line-height: 1.5;
		text-shadow: 0 1px 1px rgba(0, 0, 0, 0.03);
	}

	.ai-carousel-feature {
		display: flex;
		justify-content: center;
		gap: 10px;
		margin-bottom: 20px;
		flex-wrap: wrap;
	}

	.ai-feature-tag {
		background: rgba(255, 255, 255, 0.6);
		backdrop-filter: blur(10px);
		padding: 5px 12px;
		border-radius: 20px;
		font-size: 12px;
		color: #333;
		border: 1px solid rgba(0, 0, 0, 0.06);
		box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05);
		transition: all 0.3s ease;
	}

	.ai-feature-tag:hover {
		transform: translateY(-1px);
		box-shadow: 0 3px 6px rgba(0, 0, 0, 0.1);
	}

	.ai-carousel-button {
		background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
		color: white;
		border: none;
		padding: 10px 24px;
		border-radius: 25px;
		font-size: 13px;
		font-weight: 500;
		cursor: pointer;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		box-shadow: 0 4px 15px rgba(102, 126, 234, 0.3);
		transition: all 0.3s ease;
		margin-bottom: 10px;
		position: relative;
		overflow: hidden;
	}

	.ai-carousel-button::before {
		content: '';
		position: absolute;
		top: 50%;
		left: 50%;
		width: 0;
		height: 0;
		background: rgba(255, 255, 255, 0.2);
		border-radius: 50%;
		transform: translate(-50%, -50%);
		transition:
			width 0.6s ease,
			height 0.6s ease;
	}

	.ai-carousel-button:hover::before {
		width: 300px;
		height: 300px;
	}

	.ai-carousel-button:hover {
		transform: translateY(-2px);
		box-shadow: 0 6px 20px rgba(102, 126, 234, 0.4);
	}

	.ai-carousel-icon {
		font-size: 48px;
		margin-top: 10px;
		filter: drop-shadow(0 4px 8px rgba(0, 0, 0, 0.1));
		animation: bounce 3s ease-in-out infinite;
		position: relative;
		z-index: 2;
	}

	@keyframes bounce {
		0%,
		100% {
			transform: translateY(0);
		}
		50% {
			transform: translateY(-10px);
		}
	}

	.ai-carousel-indicators {
		display: flex;
		justify-content: center;
		gap: 8px;
		position: absolute;
		bottom: 16px;
		left: 50%;
		transform: translateX(-50%);
		z-index: 3;
	}

	.ai-carousel-dot {
		width: 10px;
		height: 10px;
		border-radius: 50%;
		background: rgba(0, 0, 0, 0.3);
		border: none;
		cursor: pointer;
		transition: all 0.3s ease;
		padding: 0;
		position: relative;
	}

	.ai-carousel-dot.active {
		background: #6653fe;
		width: 10px;
		height: 10px;
		border-radius: 50%;
	}

	.ai-carousel-dot:hover {
		background: rgba(102, 83, 254, 0.6);
		transform: scale(1.1);
	}

	:global(.dark) .ai-carousel-dot {
		background: rgba(255, 255, 255, 0.3);
	}

	:global(.dark) .ai-carousel-dot.active {
		background: #6653fe;
	}

	:global(.dark) .ai-carousel-dot:hover {
		background: rgba(102, 83, 254, 0.8);
		transform: scale(1.1);
	}

	.ai-avatar-decoration {
		position: absolute;
		bottom: 16px;
		right: 16px;
		width: 80px;
		height: 80px;
		opacity: 0.6;
	}

	.ai-avatar-decoration::before {
		content: '👨‍💼';
		font-size: 60px;
		position: absolute;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
	}

	/* 装饰性元素 */
	.ai-decorator-dot {
		position: absolute;
		width: 5px;
		height: 5px;
		background: rgba(255, 255, 255, 0.4);
		border-radius: 50%;
	}

	.ai-decorator-line {
		position: absolute;
		height: 1px;
		background: linear-gradient(
			90deg,
			transparent 0%,
			rgba(255, 255, 255, 0.3) 50%,
			transparent 100%
		);
	}

	/* 响应式设计 */
	@media (max-width: 1024px) {
		.ai-main-content {
			grid-template-columns: 1fr 1fr;
		}

		.ai-carousel-card {
			grid-column: 1 / -1;
		}
	}

	@media (max-width: 768px) {
		.ai-main-content {
			grid-template-columns: 1fr;
			gap: 12px;
		}

		.ai-tools-grid {
			grid-template-columns: repeat(2, 1fr);
		}

		.ai-assistant-content {
			padding: 16px;
		}

		.ai-header {
			margin-bottom: 16px;
		}

		.ai-card {
			padding: 12px;
		}

		/* 确保轮播卡片在移动端也没有padding */
		.ai-card.ai-carousel-card {
			padding: 0 !important;
		}
	}

	/* 暗色模式适配 */
	:global(.dark) .ai-assistant-container {
		background-color: transparent;
	}

	:global(.dark) .ai-card {
		background: rgba(30, 30, 30, 0.7);
		backdrop-filter: blur(10px);
		box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3);
		border: 1px solid rgba(255, 255, 255, 0.05);
	}

	:global(.dark) .ai-card-title {
		color: #f0f0f0;
	}

	/* 暗色模式下的头部样式 */
	:global(.dark) .text_1 {
		color: rgba(255, 255, 255, 1);
	}

	:global(.dark) .text_2 {
		color: rgba(145, 145, 145, 1);
	}

	:global(.dark) .ai-header-text p,
	:global(.dark) .ai-agent-info p {
		color: #999;
	}

	:global(.dark) .ai-tool-name,
	:global(.dark) .ai-agent-info h3,
	:global(.dark) .ai-carousel-input {
		color: #e0e0e0;
	}

	:global(.dark) .ai-tools-card {
		background: url(/assets/images/SketchPn_8.png)
			100% no-repeat;
		background-size: 100% 100%;
	}

	:global(.dark) .ai-agents-card {
		background: linear-gradient(135deg, rgba(30, 26, 36, 0.8) 0%, rgba(37, 32, 40, 0.8) 100%);
	}

	/* 暗色模式下的精选工具样式 */
	:global(.dark) .text_3 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .text_4 {
		color: rgba(235, 146, 54, 1);
	}
	:global(.dark) .text_5 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .text_6 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .paragraph_1 {
		color: rgba(145, 145, 145, 1);
	}
	:global(.dark) .text_7 {
		color: rgba(145, 145, 145, 1);
	}

	/* 暗色模式下的效率工具样式 */
	:global(.dark) .text_8 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .text_9 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .text_10 {
		color: rgba(145, 145, 145, 1);
	}
	:global(.dark) .text_11 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .text_12 {
		color: rgba(145, 145, 145, 1);
	}
	:global(.dark) .text_13 {
		color: rgba(255, 255, 255, 1);
	}
	:global(.dark) .text_14 {
		color: rgba(145, 145, 145, 1);
	}
	:global(.dark) .box_6 {
		background-color: rgba(42, 42, 42, 1);
	}
	:global(.dark) .box_7 {
		background-color: rgba(42, 42, 42, 1);
	}

	:global(.dark) .ai-tool-item,
	:global(.dark) .ai-agent-item {
		background: rgba(30, 30, 30, 0.8);
		border-color: rgba(255, 255, 255, 0.03);
	}

	:global(.dark) .ai-agent-item {
		background: rgba(30, 30, 30, 0.8);
	}

	:global(.dark) .ai-tool-item:nth-child(1) {
		background: linear-gradient(135deg, rgba(60, 50, 30, 0.8) 0%, rgba(50, 40, 20, 0.8) 100%);
	}

	:global(.dark) .ai-tool-item:nth-child(2) {
		background: linear-gradient(135deg, rgba(30, 60, 30, 0.8) 0%, rgba(20, 50, 20, 0.8) 100%);
	}

	:global(.dark) .ai-tool-item:nth-child(3) {
		background: linear-gradient(135deg, rgba(30, 30, 60, 0.8) 0%, rgba(20, 20, 50, 0.8) 100%);
	}

	:global(.dark) .ai-tool-item:nth-child(4) {
		background: linear-gradient(135deg, rgba(60, 30, 60, 0.8) 0%, rgba(50, 20, 50, 0.8) 100%);
	}

	:global(.dark) .ai-tool-item:hover {
		transform: translateY(-3px);
		box-shadow: 0 6px 16px rgba(0, 0, 0, 0.3);
		border-color: rgba(255, 255, 255, 0.06);
	}

	:global(.dark) .ai-tool-icon {
		background: rgba(0, 0, 0, 0.3);
	}

	:global(.dark) .ai-carousel-input-area {
		background: rgba(30, 30, 30, 0.95);
	}

	:global(.dark) .ai-carousel-button {
		background: #2a2a2a;
		color: #e0e0e0;
	}

	:global(.dark) .ai-carousel-icon {
		background: #e0e0e0;
	}

	:global(.dark) .ai-carousel-button:hover {
		background: #3a3a3a;
	}

	:global(.dark) .ai-carousel-title {
		color: #f0f0f0;
	}

	:global(.dark) .ai-carousel-desc {
		color: rgba(255, 255, 255, 0.7);
	}

	:global(.dark) .ai-feature-tag {
		background: rgba(255, 255, 255, 0.1);
		color: #e0e0e0;
	}

	.ai-carousel-dot:hover {
		background: rgba(255, 255, 255, 0.6);
	}

	:global(.dark) .ai-carousel-card {
		background: transparent;
	}

	/* 暗色模式下也要覆盖基础卡片样式 */
	:global(.dark) .ai-card.ai-carousel-card {
		padding: 0 !important;
		border: none !important;
		background: transparent !important;
		box-shadow: none !important;
	}

	:global(.dark) .ai-slide-unified {
		background: url(/assets/images/SketchPn_7.png)
			100% no-repeat;
		background-size: 100% 100%;
	}

	:global(.dark) .ai-carousel-container {
		box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3);
	}

	:global(.dark) .ai-carousel-title {
		color: #f0f0f0;
		text-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
	}

	:global(.dark) .ai-carousel-desc {
		color: #d0d0d0;
		text-shadow: 0 1px 1px rgba(0, 0, 0, 0.2);
	}

	:global(.dark) .ai-feature-tag {
		background: rgba(255, 255, 255, 0.1);
		color: #e0e0e0;
		border: 1px solid rgba(255, 255, 255, 0.1);
		box-shadow: 0 2px 4px rgba(0, 0, 0, 0.2);
	}

	:global(.dark) .ai-carousel-button {
		background: linear-gradient(135deg, #5a6ad8 0%, #6b4ba2 100%);
		box-shadow: 0 4px 15px rgba(90, 106, 216, 0.3);
	}

	:global(.dark) .ai-carousel-button:hover {
		box-shadow: 0 6px 20px rgba(90, 106, 216, 0.4);
	}

	/* PPT轮播模块的新样式 */
	.group_10 {
		position: relative;
		width: 100%;
		height: 100%;
		background: url(/assets/images/SketchPn_7.png)
			100% no-repeat;
		background-size: 100% 100%;
		display: flex;
		flex-direction: column;
		border-radius: 20px;
		overflow: hidden;
	}

	.group_11 {
		background-image: url(/assets/images/merge_image_4.png);
		height: 212px;
		width: 261px;
		position: relative;
		margin: 8px 0 0 24px;
	}

	.box_9 {
		width: 69px;
		height: 18px;
		margin-left: 158px;
	}

	.text-wrapper_3 {
		height: 18px;
		border: 0.5px solid rgba(255, 255, 255, 0.3);
		background: url(/assets/images/SketchPn_3.png) -8px
			0px no-repeat;
		background-size: 85px 32px;
		width: 69px;
	}

	.text_15 {
		width: 44px;
		height: 16px;
		overflow-wrap: break-word;
		color: rgba(255, 255, 255, 1);
		font-size: 11px;
		font-family: PingFangSC-Semibold;
		font-weight: 600;
		text-align: center;
		white-space: nowrap;
		line-height: 16px;
		margin: 1px 0 0 13px;
	}

	.box_10 {
		width: 78px;
		height: 27px;
		margin: 134px 0 33px 156px;
	}

	.text-wrapper_4 {
		height: 27px;
		border: 0.5px solid rgba(255, 255, 255, 0.6);
		background: url(/assets/images/SketchPn_4.png) -8px -2px
			no-repeat;
		background-size: 94px 43px;
		width: 78px;
	}

	.text_16 {
		width: 56px;
		height: 16px;
		overflow-wrap: break-word;
		color: rgba(255, 255, 255, 1);
		font-size: 14px;
		font-family: PingFangSC-Semibold;
		font-weight: 600;
		text-align: center;
		white-space: nowrap;
		line-height: 16px;
		margin: 6px 0 0 11px;
	}

	.box_11 {
		position: absolute;
		left: 6px;
		top: 24px;
		width: 197px;
		height: 145px;
	}

	.group_12 {
		box-shadow: inset 0px 0px 23px 6px rgba(255, 255, 255, 1);
		border-radius: 50%;
		position: relative;
		width: 145px;
		height: 145px;
		border: 0.5px solid rgba(255, 255, 255, 1);
		margin-left: 52px;
	}

	.text_17 {
		width: 28px;
		height: 10px;
		overflow-wrap: break-word;
		color: rgba(255, 255, 255, 1);
		font-size: 10px;
		font-family: AlimamaFangYuanTiVF-Light;
		font-weight: 300;
		text-align: left;
		white-space: nowrap;
		line-height: 12px;
		margin: 20px 0 0 83px;
	}

	.group_13 {
		width: 94px;
		height: 29px;
		margin: 7px 0 0 30px;
	}

	.text_18 {
		width: 27px;
		height: 10px;
		overflow-wrap: break-word;
		color: rgba(255, 255, 255, 1);
		font-size: 10px;
		font-family: AlimamaFangYuanTiVF-Light;
		font-weight: 300;
		text-align: left;
		white-space: nowrap;
		line-height: 12px;
	}

	.image_4 {
		width: 60px;
		height: 28px;
		margin-top: 1px;
	}

	.group_14 {
		height: 48px;
		background: url(/assets/images/SketchPn_21.png) -4px -4px
			no-repeat;
		background-size: 119px 64px;
		width: 104px;
		margin: 12px 0 19px 21px;
	}

	.section_2 {
		height: 33px;
		background: url(/assets/images/SketchPn_18.png) -1px -1px
			no-repeat;
		background-size: 105px 34px;
		margin-top: -16px;
		width: 104px;
		position: relative;
	}

	.text_19 {
		width: 35px;
		height: 10px;
		overflow-wrap: break-word;
		color: rgba(245, 246, 255, 1);
		font-size: 10px;
		font-family: AlimamaFangYuanTiVF-Light;
		font-weight: 300;
		text-align: left;
		white-space: nowrap;
		line-height: 12px;
		margin: 20px 0 0 31px;
	}

	.image_5 {
		position: absolute;
		left: 54px;
		top: -32px;
		width: 1px;
		height: 49px;
	}

	.label_6 {
		position: absolute;
		left: 41px;
		top: -14px;
		width: 30px;
		height: 40px;
	}

	.image_6 {
		position: absolute;
		left: 3px;
		top: -12px;
		width: 43px;
		height: 18px;
	}

	.label_7 {
		position: absolute;
		left: 24px;
		top: 57px;
		width: 43px;
		height: 22px;
	}

	.text-wrapper_5 {
		height: 24px;
		border: 0.5px solid rgba(255, 255, 255, 0.6);
		background: url(/assets/images/SketchPn_17.png) -6px -2px
			no-repeat;
		background-size: 107px 40px;
		width: 93px;
		position: absolute;
		left: 0;
		top: 30px;
	}

	.text_20 {
		width: 72px;
		height: 16px;
		overflow-wrap: break-word;
		color: rgba(255, 255, 255, 1);
		font-size: 12px;
		font-family: PingFangSC-Semibold;
		font-weight: 600;
		text-align: center;
		white-space: nowrap;
		line-height: 16px;
		margin: 4px 0 0 11px;
	}

	.text-wrapper_6 {
		height: 44px;
		background: url(/assets/images/SketchPn_2.png) -7px -6px
			no-repeat;
		background-size: 314px 56px;
		width: 304px;
		position: absolute;
		left: 6px;
		top: 200px;
	}

	.text_21 {
		width: 128px;
		height: 24px;
		overflow-wrap: break-word;
		color: rgba(0, 0, 0, 1);
		font-size: 16px;
		font-family: SourceHanSansSC-Bold;
		font-weight: 700;
		text-align: left;
		white-space: nowrap;
		line-height: 24px;
		margin: 10px 0 0 88px;
	}

	/* PPT工具新样式 */
	.ppt-tool-container {
		position: relative;
		width: 100%;
		height: 240px;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
	}

	.ppt-merged-gif {
		width: 280px;
		height: 180px;
		margin-top: -50px;
		object-fit: contain;
		image-rendering: auto;
		pointer-events: none;
	}

	.ppt-tool-title {
		position: absolute;
		bottom: 10px;
		left: 50%;
		transform: translateX(-50%);
		height: 44px;
		background: url(/assets/images/SketchPn_2.png) center center no-repeat;
		background-size: 304px 56px;
		width: 304px;
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.ppt-tool-title .text_21 {
		margin: 0;
		text-align: center;
	}

	/* 暗色模式下的PPT轮播样式 */
	:global(.dark) .text_15,
	:global(.dark) .text_16,
	:global(.dark) .text_17,
	:global(.dark) .text_18,
	:global(.dark) .text_19,
	:global(.dark) .text_20 {
		color: rgba(255, 255, 255, 1);
	}

	:global(.dark) .text_21 {
		color: rgba(255, 255, 255, 1);
	}

	/* 暗色模式下的PPT工具样式 */
	:global(.dark) .ppt-tool-title .text_21 {
		color: rgba(255, 255, 255, 1);
	}

	:global(.dark) .group_10 {
		background: url(/assets/images/SketchPn_7.png)
			100% no-repeat;
		background-size: 100% 100%;
	}

	/* Flex布局工具类 */
	.flex-col {
		display: flex;
		flex-direction: column;
	}

	.flex-row {
		display: flex;
		flex-direction: row;
	}

	.justify-between {
		display: flex;
		justify-content: space-between;
	}

	.ai-assistant::-webkit-scrollbar {
		width: 0.4rem !important;
		height: 0.4rem !important;
	}

	/* AI助手界面DPI缩放支持 */
	.ai-assistant {
		transition: transform 0.1s ease-in-out;
		overflow: visible;
	}


	@media (min-width: 1366px) and (max-width: 1920px) {
		.ai-assistant{
			padding:0 24px !important;
		}
		.ai-main-content{
			gap: 10px !important;
		}
	}

	@media (min-width: 1920px) {
		.ai-assistant{
			margin-top: 64px !important;
		}
	}

	@media (min-width: 1024px) and (max-width: 1366px) {
		.ai-main-content {
			width: 1200px;
		}
		.ai-assistant{
			padding:0 24px !important;
		}
		.ai-main-content {
			grid-template-columns: 540px 339px 339px !important;
		}
		.text-wrapper_2 {
			width: 506px !important;
		}
		.text-wrapper_6{
			background-size: 264px 56px !important;
			left: 25px !important;
		}
		.group_5{
			width: 508px !important;
		}
		.box_5 {
			width: 304px !important;
		}
		.box_6 {
			width: 304px !important;
		}
		.box_7 {
			width: 304px !important;
		}
		.ai-agents-card {
			width: 540px !important;
		}
		.ai-tools-card {
			width: 339px !important;
		}
		.ai-carousel-card{
			width: 339px !important;
		}
	}
</style>
